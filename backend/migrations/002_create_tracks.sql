BEGIN;

CREATE TABLE tracks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    album_id UUID NOT NULL REFERENCES albums(id) ON DELETE RESTRICT,
    title TEXT NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 256),
    artist TEXT NOT NULL CHECK (char_length(btrim(artist)) BETWEEN 1 AND 256),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'ready')),
    storage_bucket TEXT,
    object_key TEXT,
    content_type TEXT,
    size_bytes BIGINT CHECK (size_bytes > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    uploaded_at TIMESTAMPTZ,
    CONSTRAINT tracks_upload_state CHECK (
        (status = 'pending' AND storage_bucket IS NULL AND object_key IS NULL
            AND content_type IS NULL AND size_bytes IS NULL AND uploaded_at IS NULL)
        OR
        (status = 'ready' AND storage_bucket IS NOT NULL AND object_key IS NOT NULL
            AND content_type IS NOT NULL AND size_bytes IS NOT NULL AND uploaded_at IS NOT NULL)
    ),
    UNIQUE (storage_bucket, object_key)
);

CREATE INDEX tracks_album_id_idx ON tracks(album_id);

COMMIT;
