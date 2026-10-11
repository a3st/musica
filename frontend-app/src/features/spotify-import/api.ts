import { record, uuid } from '../../shared/api/validation';
import { t } from '../../shared/i18n';
import { request, json } from '../../shared/api/client';
import type { SpotifyImport } from './parser';

export const spotifyApi = {
  /** Отправляет выбранные метаданные импорта и проверяет итоговые количества и ID плейлистов. */
  async importSpotify(input: SpotifyImport): Promise<{ tracks: number; playlists: string[] }> {
    const r = record(
      await request('/spotify/import', {
        method: 'POST',
        signal: AbortSignal.timeout(120000),
        ...json(input),
      }),
    );
    if (
      !Array.isArray(r.playlists) ||
      typeof r.tracks !== 'number' ||
      !Number.isSafeInteger(r.tracks) ||
      r.tracks < 0
    )
      throw new Error(t('errors.invalidImportResult'));

    return { tracks: r.tracks, playlists: r.playlists.map(uuid) };
  },
};
