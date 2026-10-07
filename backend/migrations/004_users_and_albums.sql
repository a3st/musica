BEGIN;

CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username TEXT NOT NULL UNIQUE CHECK (username ~ '^[a-z0-9_]{3,64}$'),
    password_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE albums
    ALTER COLUMN artist DROP NOT NULL,
    ADD COLUMN owner_id UUID REFERENCES users(id) ON DELETE RESTRICT,
    ADD COLUMN description TEXT NOT NULL DEFAULT '' CHECK (char_length(description) <= 4096),
    ADD COLUMN tags JSONB NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(tags) = 'array' AND jsonb_array_length(tags) <= 32),
    ADD COLUMN visibility TEXT NOT NULL DEFAULT 'private' CHECK (visibility IN ('private', 'public', 'unlisted')),
    ADD COLUMN is_default BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN image_key TEXT,
    ADD COLUMN share_token_hash TEXT UNIQUE,
    ADD CONSTRAINT default_album_private CHECK (NOT is_default OR (owner_id IS NOT NULL AND visibility = 'private'));

CREATE UNIQUE INDEX albums_default_owner_idx ON albums(owner_id) WHERE is_default;
CREATE INDEX albums_owner_idx ON albums(owner_id);

-- Every new user receives a private default album in the same transaction.
CREATE FUNCTION create_user_default_album() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO albums (owner_id, title, is_default)
    VALUES (NEW.id, 'Uploads', true);
    RETURN NEW;
END;
$$;

CREATE TRIGGER users_create_default_album AFTER INSERT ON users
FOR EACH ROW EXECUTE FUNCTION create_user_default_album();

CREATE TABLE sessions (
    token_hash TEXT PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '30 days')
);
CREATE INDEX sessions_user_idx ON sessions(user_id);
CREATE INDEX sessions_expiry_idx ON sessions(expires_at);

CREATE TABLE album_members (
    album_id UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN ('viewer', 'editor')),
    PRIMARY KEY (album_id, user_id)
);
CREATE INDEX album_members_user_idx ON album_members(user_id, album_id);

ALTER TABLE tracks ADD COLUMN owner_id UUID REFERENCES users(id) ON DELETE RESTRICT;
CREATE INDEX tracks_owner_idx ON tracks(owner_id);

-- Legacy rows keep owner_id NULL and remain inaccessible via the new API.
-- Assign their owners manually after creating the appropriate users.
COMMIT;
