-- Before applying, set musica.pending_bucket to the bucket used for old uploads.
-- Example in the same SQL session: SET musica.pending_bucket = 'uploads';
BEGIN;

LOCK TABLE tracks IN ACCESS EXCLUSIVE MODE;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM tracks WHERE status = 'pending')
        AND NULLIF(current_setting('musica.pending_bucket', true), '') IS NULL THEN
        RAISE EXCEPTION 'Set musica.pending_bucket to the previous S3_BUCKET before applying this migration';
    END IF;
END;
$$;

ALTER TABLE tracks DROP CONSTRAINT tracks_upload_state;

UPDATE tracks
SET storage_bucket = current_setting('musica.pending_bucket', true),
    object_key = 'tracks/' || id::text
WHERE status = 'pending';

ALTER TABLE tracks
    ALTER COLUMN storage_bucket SET NOT NULL,
    ALTER COLUMN object_key SET NOT NULL,
    ADD CONSTRAINT tracks_storage_location CHECK (storage_bucket <> '' AND object_key <> ''),
    ADD CONSTRAINT tracks_upload_state CHECK (
        (status = 'pending' AND content_type IS NULL AND size_bytes IS NULL AND uploaded_at IS NULL)
        OR
        (status = 'ready' AND content_type IS NOT NULL AND size_bytes IS NOT NULL AND uploaded_at IS NOT NULL)
    );

COMMIT;
