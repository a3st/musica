-- Выполните вручную для существующей БД; начальная схема уже поддерживает Deezer.
BEGIN;

ALTER TABLE musica.track_sources
    DROP CONSTRAINT track_sources_provider_check;

ALTER TABLE musica.track_sources
    ADD CONSTRAINT track_sources_provider_check
    CHECK (provider IN ('spotify', 'itunes', 'deezer'));

COMMIT;
