-- Apply manually after 001_init.sql. No passwords are stored in this migration.
BEGIN;
ALTER TABLE musica.users ADD COLUMN kind TEXT NOT NULL DEFAULT 'user' CHECK (kind IN ('user','system'));
ALTER TABLE musica.users ADD COLUMN role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('user','admin'));
ALTER TABLE musica.users ALTER COLUMN password_hash DROP NOT NULL;
ALTER TABLE musica.users ADD CONSTRAINT users_credentials CHECK ((kind='system' AND password_hash IS NULL AND role='user') OR (kind='user' AND password_hash IS NOT NULL));
CREATE UNIQUE INDEX users_system_idx ON musica.users(kind) WHERE kind='system';

CREATE FUNCTION musica.track_identity(artist TEXT, title TEXT) RETURNS TEXT LANGUAGE SQL IMMUTABLE STRICT
SET search_path = pg_catalog AS $$
 SELECT json_build_array(
   normalize(lower(btrim(regexp_replace(artist, '\s+', ' ', 'g'))), NFC),
   normalize(lower(btrim(regexp_replace(regexp_replace(translate(title, '[]', '()'), '\s*([()])\s*', '\1', 'g'), '\s+', ' ', 'g'))), NFC)
 )::text;
$$;
ALTER TABLE musica.tracks ADD COLUMN catalog_key TEXT UNIQUE;
ALTER TABLE musica.tracks ADD COLUMN orphaned_at TIMESTAMPTZ;
CREATE INDEX tracks_orphaned_idx ON musica.tracks(orphaned_at) WHERE catalog_key IS NOT NULL;
CREATE TABLE musica.track_sources (
 provider TEXT NOT NULL CHECK (provider IN ('spotify','itunes')),
 external_id TEXT NOT NULL,
 track_id UUID NOT NULL REFERENCES musica.tracks(id) ON DELETE CASCADE,
 PRIMARY KEY (provider,external_id)
);
CREATE INDEX track_sources_track_idx ON musica.track_sources(track_id);
UPDATE public.jobs
SET kind='download_track', payload=jsonb_set(payload-'import_id','{track}',(payload->'track')-'spotify_uri')
WHERE kind='spotify_download'
   OR (kind='download_track' AND (payload ? 'import_id' OR (payload->'track') ? 'spotify_uri'));

CREATE FUNCTION musica.update_track_references() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,musica,public AS $$
DECLARE target UUID;
BEGIN
 target := CASE WHEN TG_OP='DELETE' THEN OLD.track_id ELSE NEW.track_id END;
 UPDATE musica.tracks t SET orphaned_at=CASE WHEN EXISTS (
   SELECT 1 FROM musica.track_playlists tp JOIN musica.playlists p ON p.id=tp.playlist_id JOIN musica.users u ON u.id=p.owner_id WHERE tp.track_id=t.id AND u.kind='user'
 ) THEN NULL ELSE COALESCE(t.orphaned_at,clock_timestamp()) END WHERE t.id=target AND t.catalog_key IS NOT NULL;
 RETURN NULL;
END;
$$;
CREATE TRIGGER track_references_changed AFTER INSERT OR DELETE ON musica.track_playlists FOR EACH ROW EXECUTE FUNCTION musica.update_track_references();
CREATE TABLE musica.catalog_cache (key TEXT PRIMARY KEY, body TEXT NOT NULL, expires_at TIMESTAMPTZ NOT NULL);
COMMIT;
