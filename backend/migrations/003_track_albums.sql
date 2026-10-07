BEGIN;

-- Keep the backfill consistent with concurrent writes by the old backend.
LOCK TABLE tracks IN ACCESS EXCLUSIVE MODE;

CREATE TABLE track_albums (
    track_id UUID NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    album_id UUID NOT NULL REFERENCES albums(id) ON DELETE RESTRICT,
    PRIMARY KEY (track_id, album_id)
);

CREATE INDEX track_albums_album_id_idx ON track_albums(album_id, track_id);

-- Preserve existing memberships before removing the single-album column.
INSERT INTO track_albums (track_id, album_id)
SELECT id, album_id FROM tracks;

ALTER TABLE tracks DROP COLUMN album_id;

COMMIT;
