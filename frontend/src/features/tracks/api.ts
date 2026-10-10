import { record, uuid } from '../../shared/api/validation';
import { request, json } from '../../shared/api/client';
import { hlsState, track, type HlsState, type Track } from './model';
import { t } from '../../shared/i18n';

export interface LibraryMatch {
  track: Track;
  playlistId: string;
}

export const tracksApi = {
  async searchLibrary(query: string, signal: AbortSignal): Promise<LibraryMatch[]> {
    const result = record(
      await request('/tracks/search?q=' + encodeURIComponent(query), {
        signal: AbortSignal.any([signal, AbortSignal.timeout(30000)]),
      }),
    );
    if (!Array.isArray(result.tracks) || result.tracks.length > 25)
      throw new Error(t('errors.invalidData'));
    const ids = new Set<string>();
    return result.tracks.map((value) => {
      const row = record(value);
      const item = track(row.track);
      if (item.owner_kind !== 'user' || item.status === 'pending' || ids.has(item.id))
        throw new Error(t('errors.invalidData'));
      ids.add(item.id);
      return { track: item, playlistId: uuid(row.playlist_id) };
    });
  },

  async createTrack(title: string, artist: string, playlistIds: string[]): Promise<string> {
    return uuid(
      record(
        await request('/tracks', {
          method: 'POST',
          ...json({ title, artist, playlist_ids: playlistIds }),
        }),
      ).id,
    );
  },
  async prepare(id: string): Promise<HlsState> {
    return hlsState(await request(`/tracks/${id}/hls`, { method: 'POST' }));
  },
  async preparation(id: string, shareToken?: string | null): Promise<HlsState> {
    return hlsState(
      await request(
        `/tracks/${id}/hls/status${shareToken ? '?share_token=' + encodeURIComponent(shareToken) : ''}`,
      ),
    );
  },
  async removeTrack(id: string): Promise<void> {
    await request('/tracks/' + id, { method: 'DELETE' });
  },
};
