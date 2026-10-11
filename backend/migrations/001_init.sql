-- Initial schema for a fresh database. Apply manually once.
BEGIN;
CREATE SCHEMA IF NOT EXISTS public;
CREATE SCHEMA IF NOT EXISTS musica;
SET LOCAL search_path = pg_catalog, musica, public;

CREATE TYPE musica.track_status AS ENUM ('pending', 'ready', 'streamed');

CREATE TABLE musica.users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username TEXT NOT NULL UNIQUE CHECK (username ~ '^[a-z0-9_]{3,64}$'),
    password_hash TEXT,
    kind TEXT NOT NULL DEFAULT 'user' CHECK (kind IN ('user', 'system')),
    role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('user', 'admin')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT users_credentials CHECK (
        (kind = 'system' AND password_hash IS NULL AND role = 'user')
        OR (kind = 'user' AND password_hash IS NOT NULL)
    )
);
CREATE UNIQUE INDEX users_system_idx ON musica.users(kind) WHERE kind = 'system';

CREATE TABLE musica.playlists (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID REFERENCES musica.users(id) ON DELETE RESTRICT,
    title TEXT NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 256),
    description TEXT NOT NULL DEFAULT '' CHECK (char_length(description) <= 4096),
    tags JSONB NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(tags) = 'array' AND jsonb_array_length(tags) <= 32),
    visibility TEXT NOT NULL DEFAULT 'private' CHECK (visibility IN ('private', 'public', 'unlisted')),
    is_default BOOLEAN NOT NULL DEFAULT false,
    image_key TEXT,
    share_token_hash TEXT UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT default_playlist_private CHECK (NOT is_default OR (owner_id IS NOT NULL AND visibility = 'private'))
);
CREATE UNIQUE INDEX playlists_default_owner_idx ON musica.playlists(owner_id) WHERE is_default;
CREATE INDEX playlists_owner_idx ON musica.playlists(owner_id);

CREATE FUNCTION musica.create_user_default_playlist() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, musica, public AS $$
BEGIN
    INSERT INTO musica.playlists (owner_id, title, is_default)
    VALUES (NEW.id, 'Uploads', true);
    RETURN NEW;
END;
$$;
CREATE TRIGGER users_create_default_playlist AFTER INSERT ON musica.users
FOR EACH ROW EXECUTE FUNCTION musica.create_user_default_playlist();

CREATE TABLE musica.sessions (
    token_hash TEXT PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES musica.users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '30 days')
);
CREATE INDEX sessions_user_idx ON musica.sessions(user_id);
CREATE INDEX sessions_expiry_idx ON musica.sessions(expires_at);

CREATE TABLE musica.playlist_members (
    playlist_id UUID NOT NULL REFERENCES musica.playlists(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES musica.users(id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN ('viewer', 'editor')),
    PRIMARY KEY (playlist_id, user_id)
);
CREATE INDEX playlist_members_user_idx ON musica.playlist_members(user_id, playlist_id);

CREATE FUNCTION musica.track_identity(artist TEXT, title TEXT) RETURNS TEXT LANGUAGE SQL IMMUTABLE STRICT
SET search_path = pg_catalog AS $$
    SELECT json_build_array(
        normalize(lower(btrim(regexp_replace(artist, '\s+', ' ', 'g'))), NFC),
        normalize(lower(btrim(regexp_replace(
            regexp_replace(translate(title, '[]', '()'), '\s*([()])\s*', '\1', 'g'),
            '\s+', ' ', 'g'
        ))), NFC)
    )::text;
$$;

CREATE TABLE musica.tracks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID REFERENCES musica.users(id) ON DELETE RESTRICT,
    title TEXT NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 256),
    artist TEXT NOT NULL CHECK (char_length(btrim(artist)) BETWEEN 1 AND 256),
    status musica.track_status NOT NULL DEFAULT 'pending',
    storage_bucket TEXT NOT NULL,
    object_key TEXT NOT NULL,
    content_type TEXT,
    size_bytes BIGINT CHECK (size_bytes > 0),
    duration_seconds INTEGER CHECK (duration_seconds >= 0),
    artwork_key TEXT CHECK (artwork_key <> ''),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    uploaded_at TIMESTAMPTZ,
    hls_bucket TEXT,
    hls_prefix TEXT,
    hls_segment_count INTEGER,
    catalog_key TEXT UNIQUE,
    orphaned_at TIMESTAMPTZ,
    CONSTRAINT tracks_storage_location CHECK (storage_bucket <> '' AND object_key <> ''),
    CONSTRAINT tracks_upload_state CHECK (
        (status = 'pending' AND content_type IS NULL AND size_bytes IS NULL AND uploaded_at IS NULL)
        OR (status IN ('ready', 'streamed') AND content_type IS NOT NULL AND size_bytes IS NOT NULL AND uploaded_at IS NOT NULL)
    ),
    CONSTRAINT tracks_hls_state CHECK (
        (status = 'streamed' AND hls_bucket IS NOT NULL AND hls_bucket <> ''
            AND hls_prefix IS NOT NULL AND hls_prefix <> '' AND hls_segment_count IS NOT NULL
            AND hls_segment_count BETWEEN 1 AND 10000)
        OR (status <> 'streamed' AND hls_bucket IS NULL AND hls_prefix IS NULL AND hls_segment_count IS NULL)
    ),
    UNIQUE (storage_bucket, object_key)
);
CREATE INDEX tracks_owner_idx ON musica.tracks(owner_id);
CREATE INDEX tracks_orphaned_idx ON musica.tracks(orphaned_at) WHERE catalog_key IS NOT NULL;

CREATE TABLE musica.track_sources (
    provider TEXT NOT NULL CHECK (provider IN ('spotify', 'itunes', 'deezer')),
    external_id TEXT NOT NULL,
    track_id UUID NOT NULL REFERENCES musica.tracks(id) ON DELETE CASCADE,
    PRIMARY KEY (provider, external_id)
);
CREATE INDEX track_sources_track_idx ON musica.track_sources(track_id);

CREATE TABLE musica.track_playlists (
    track_id UUID NOT NULL REFERENCES musica.tracks(id) ON DELETE CASCADE,
    playlist_id UUID NOT NULL REFERENCES musica.playlists(id) ON DELETE RESTRICT,
    PRIMARY KEY (track_id, playlist_id)
);
CREATE INDEX track_playlists_playlist_id_idx ON musica.track_playlists(playlist_id, track_id);

CREATE FUNCTION musica.update_track_references() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, musica, public AS $$
DECLARE
    target UUID;
BEGIN
    target := CASE WHEN TG_OP = 'DELETE' THEN OLD.track_id ELSE NEW.track_id END;
    UPDATE musica.tracks t
    SET orphaned_at = CASE WHEN EXISTS (
        SELECT 1
        FROM musica.track_playlists tp
        JOIN musica.playlists p ON p.id = tp.playlist_id
        JOIN musica.users u ON u.id = p.owner_id
        WHERE tp.track_id = t.id AND u.kind = 'user'
    ) THEN NULL ELSE COALESCE(t.orphaned_at, clock_timestamp()) END
    WHERE t.id = target AND t.catalog_key IS NOT NULL;
    RETURN NULL;
END;
$$;
CREATE TRIGGER track_references_changed AFTER INSERT OR DELETE ON musica.track_playlists
FOR EACH ROW EXECUTE FUNCTION musica.update_track_references();

CREATE TABLE musica.catalog_cache (
    key TEXT PRIMARY KEY,
    body TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE public.jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kind TEXT NOT NULL CHECK (kind <> ''),
    dedupe_key TEXT,
    state TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued', 'processing', 'completed', 'failed')),
    attempt_id UUID,
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    max_attempts INTEGER CHECK (max_attempts > 0),
    lease_until TIMESTAMPTZ,
    available_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    payload JSONB NOT NULL,
    UNIQUE (kind, dedupe_key),
    CONSTRAINT jobs_lease CHECK (
        (state = 'processing' AND attempt_id IS NOT NULL AND lease_until IS NOT NULL)
        OR (state <> 'processing' AND lease_until IS NULL)
    )
);
CREATE INDEX jobs_queue_idx ON public.jobs(kind, available_at, created_at) WHERE state = 'queued';
CREATE INDEX jobs_lease_idx ON public.jobs(kind, lease_until) WHERE state = 'processing';

COMMIT;
