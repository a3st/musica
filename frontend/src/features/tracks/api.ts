import { record, uuid } from '../../shared/api/validation';
import { request, json } from '../../shared/api/client';
import { hlsState, type HlsState } from './model';
export const tracksApi = {
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
