BEGIN;

ALTER TYPE track_status ADD VALUE 'streamed';
CREATE TYPE hls_job_state AS ENUM ('queued', 'processing', 'ready', 'failed');

ALTER TABLE tracks
    DROP CONSTRAINT tracks_upload_state,
    ADD COLUMN hls_bucket TEXT,
    ADD COLUMN hls_prefix TEXT,
    ADD COLUMN hls_segment_count INTEGER,
    ADD CONSTRAINT tracks_upload_state CHECK (
        (status::text = 'pending' AND content_type IS NULL AND size_bytes IS NULL AND uploaded_at IS NULL)
        OR
        (status::text IN ('ready', 'streamed') AND content_type IS NOT NULL AND size_bytes IS NOT NULL AND uploaded_at IS NOT NULL)
    ),
    ADD CONSTRAINT tracks_hls_state CHECK (
        (status::text = 'streamed' AND hls_bucket IS NOT NULL AND hls_bucket <> ''
            AND hls_prefix IS NOT NULL AND hls_prefix <> '' AND hls_segment_count IS NOT NULL
            AND hls_segment_count BETWEEN 1 AND 10000)
        OR
        (status::text <> 'streamed' AND hls_bucket IS NULL AND hls_prefix IS NULL AND hls_segment_count IS NULL)
    );

CREATE TABLE track_hls_jobs (
    track_id UUID PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
    state hls_job_state NOT NULL DEFAULT 'queued',
    attempt_id UUID,
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    lease_until TIMESTAMPTZ,
    available_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT track_hls_jobs_lease CHECK (
        (state = 'processing' AND attempt_id IS NOT NULL AND lease_until IS NOT NULL)
        OR (state <> 'processing' AND lease_until IS NULL)
    )
);
CREATE INDEX track_hls_jobs_queue_idx ON track_hls_jobs (available_at, created_at) WHERE state = 'queued';
CREATE INDEX track_hls_jobs_lease_idx ON track_hls_jobs (lease_until) WHERE state = 'processing';

COMMIT;
