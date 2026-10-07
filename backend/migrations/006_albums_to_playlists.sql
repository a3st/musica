BEGIN;

LOCK TABLE users, albums, track_albums, album_members IN ACCESS EXCLUSIVE MODE;

DROP TRIGGER users_create_default_album ON users;
DROP FUNCTION create_user_default_album();

ALTER TABLE albums RENAME TO playlists;
ALTER TABLE track_albums RENAME TO track_playlists;
ALTER TABLE track_playlists RENAME COLUMN album_id TO playlist_id;
ALTER TABLE album_members RENAME TO playlist_members;
ALTER TABLE playlist_members RENAME COLUMN album_id TO playlist_id;

ALTER TABLE playlists RENAME CONSTRAINT albums_pkey TO playlists_pkey;
ALTER TABLE playlists RENAME CONSTRAINT albums_title_check TO playlists_title_check;
ALTER TABLE playlists RENAME CONSTRAINT albums_artist_check TO playlists_artist_check;
ALTER TABLE playlists RENAME CONSTRAINT albums_owner_id_fkey TO playlists_owner_id_fkey;
ALTER TABLE playlists RENAME CONSTRAINT albums_description_check TO playlists_description_check;
ALTER TABLE playlists RENAME CONSTRAINT albums_tags_check TO playlists_tags_check;
ALTER TABLE playlists RENAME CONSTRAINT albums_visibility_check TO playlists_visibility_check;
ALTER TABLE playlists RENAME CONSTRAINT albums_share_token_hash_key TO playlists_share_token_hash_key;
ALTER TABLE playlists RENAME CONSTRAINT default_album_private TO default_playlist_private;
ALTER INDEX albums_default_owner_idx RENAME TO playlists_default_owner_idx;
ALTER INDEX albums_owner_idx RENAME TO playlists_owner_idx;

ALTER TABLE track_playlists RENAME CONSTRAINT track_albums_pkey TO track_playlists_pkey;
ALTER TABLE track_playlists RENAME CONSTRAINT track_albums_track_id_fkey TO track_playlists_track_id_fkey;
ALTER TABLE track_playlists RENAME CONSTRAINT track_albums_album_id_fkey TO track_playlists_playlist_id_fkey;
ALTER INDEX track_albums_album_id_idx RENAME TO track_playlists_playlist_id_idx;

ALTER TABLE playlist_members RENAME CONSTRAINT album_members_pkey TO playlist_members_pkey;
ALTER TABLE playlist_members RENAME CONSTRAINT album_members_album_id_fkey TO playlist_members_playlist_id_fkey;
ALTER TABLE playlist_members RENAME CONSTRAINT album_members_user_id_fkey TO playlist_members_user_id_fkey;
ALTER TABLE playlist_members RENAME CONSTRAINT album_members_role_check TO playlist_members_role_check;
ALTER INDEX album_members_user_idx RENAME TO playlist_members_user_idx;

CREATE FUNCTION create_user_default_playlist() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO playlists (owner_id, title, is_default)
    VALUES (NEW.id, 'Uploads', true);
    RETURN NEW;
END;
$$;

CREATE TRIGGER users_create_default_playlist AFTER INSERT ON users
FOR EACH ROW EXECUTE FUNCTION create_user_default_playlist();

-- IDs, memberships, permissions, share tokens and stored S3 keys are preserved.
COMMIT;
