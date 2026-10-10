BEGIN;

ALTER TABLE musica.tracks
    ADD COLUMN duration_seconds INTEGER CHECK (duration_seconds >= 0),
    ADD COLUMN artwork_key TEXT CHECK (artwork_key <> '');

-- Обрабатываем существующие исходники тем же worker, что и новые загрузки.
INSERT INTO public.jobs (kind, dedupe_key, payload, max_attempts)
SELECT 'inspect_track', id::text,
    jsonb_build_object('track_id', id, 'bucket', storage_bucket,
        'key', object_key, 'size', size_bytes), 3
FROM musica.tracks
WHERE status IN ('ready', 'streamed')
ON CONFLICT (kind, dedupe_key) DO NOTHING;

COMMIT;
