BEGIN;

CREATE TABLE albums (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 256),
    artist TEXT NOT NULL CHECK (char_length(btrim(artist)) BETWEEN 1 AND 256),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMIT;
