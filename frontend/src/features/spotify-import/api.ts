import { record, uuid } from '../../shared/api/validation';
import { t } from '../../shared/i18n';
import { request, json } from '../../shared/api/client';
import { spotifyStatus, type SpotifyImportStatus } from './model';
export const spotifyApi = {
  async importSpotify(
    input: import('./parser').SpotifyImport,
  ): Promise<{ id: string; tracks: number; playlists: string[] }> {
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
    return { id: uuid(r.id), tracks: r.tracks, playlists: r.playlists.map(uuid) };
  },
  async spotifyImportStatus(id: string): Promise<SpotifyImportStatus> {
    return spotifyStatus(await request(`/spotify/imports/${id}`));
  },
  async retrySpotifyImport(id: string): Promise<SpotifyImportStatus> {
    return spotifyStatus(await request(`/spotify/imports/${id}/retry`, { method: 'POST' }));
  },
};
