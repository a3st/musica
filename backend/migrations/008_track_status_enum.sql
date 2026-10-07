BEGIN;

LOCK TABLE tracks IN ACCESS EXCLUSIVE MODE;

CREATE TYPE track_status AS ENUM ('pending', 'ready');

ALTER TABLE tracks
    DROP CONSTRAINT tracks_status_check,
    DROP CONSTRAINT tracks_upload_state,
    ALTER COLUMN status DROP DEFAULT;

ALTER TABLE tracks
    ALTER COLUMN status TYPE track_status USING status::track_status,
    ALTER COLUMN status SET DEFAULT 'pending'::track_status,
    ADD CONSTRAINT tracks_upload_state CHECK (
        (status = 'pending' AND content_type IS NULL AND size_bytes IS NULL AND uploaded_at IS NULL)
        OR
        (status = 'ready' AND content_type IS NOT NULL AND size_bytes IS NOT NULL AND uploaded_at IS NOT NULL)
    );

COMMIT;
