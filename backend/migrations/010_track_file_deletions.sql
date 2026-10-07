BEGIN;
CREATE TABLE track_file_deletions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bucket TEXT NOT NULL CHECK (bucket <> ''),
    object_keys JSONB NOT NULL CHECK (jsonb_typeof(object_keys) = 'array' AND jsonb_array_length(object_keys) BETWEEN 1 AND 10002),
    state TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued', 'processing')),
    attempt_id UUID,
    lease_until TIMESTAMPTZ,
    available_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT track_file_deletions_lease CHECK (
        (state = 'processing' AND attempt_id IS NOT NULL AND lease_until IS NOT NULL)
        OR (state = 'queued' AND lease_until IS NULL)
    )
);
CREATE INDEX track_file_deletions_queue_idx ON track_file_deletions (available_at);
COMMIT;
