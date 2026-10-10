import { record, text, uuid, choice } from '../../shared/api/validation';
import { t } from '../../shared/i18n';
import { request, json } from '../../shared/api/client';
import { playlist, metadata, type Playlist, type PlaylistSummary } from './model';
export const playlistsApi = {
  async playlists(): Promise<PlaylistSummary[]> {
    const data = await request('/playlists');
    if (!Array.isArray(data)) throw new Error(t('errors.invalidPlaylistList'));
    return data.map((item: unknown) => {
      const r = record(item);
      const count = r.track_count;
      if (typeof count !== 'number' || !Number.isSafeInteger(count) || count < 0)
        throw new Error(t('errors.invalidTrackCount'));
      return {
        ...metadata(item),
        role: choice(r.role, ['owner', 'editor', 'viewer'] as const),
        track_count: count,
      };
    });
  },
  async playlist(id: string): Promise<Playlist> {
    return playlist(await request('/playlists/' + id));
  },
  async sharedPlaylist(token: string): Promise<Playlist> {
    return playlist(await request('/shared/playlists/' + encodeURIComponent(token)));
  },
  async createShareLink(id: string): Promise<string> {
    const path = text(
      record(await request(`/playlists/${id}/share-link`, { method: 'POST' })).path,
    );
    const token = /^\/api\/shared\/playlists\/([0-9a-f]{64})$/.exec(path)?.[1];
    if (!token) throw new Error(t('errors.invalidResponse'));
    return token;
  },
  async createPlaylist(
    title: string,
    description: string,
    visibility: Playlist['visibility'],
  ): Promise<string> {
    return uuid(
      record(
        await request('/playlists', {
          method: 'POST',
          ...json({ title, description, visibility }),
        }),
      ).id,
    );
  },
  async updatePlaylist(
    id: string,
    title: string,
    description: string,
    visibility: Playlist['visibility'],
    tags: string[],
  ): Promise<void> {
    await request('/playlists/' + id, {
      method: 'PUT',
      ...json({ title, description, visibility, tags }),
    });
  },
  async setPlaylistImage(id: string, file: File): Promise<void> {
    const mime =
      file.type ||
      (/\.png$/i.test(file.name)
        ? 'image/png'
        : /\.webp$/i.test(file.name)
          ? 'image/webp'
          : 'image/jpeg');
    await request(`/playlists/${id}/image`, {
      method: 'PUT',
      headers: { 'Content-Type': mime },
      body: file,
      signal: AbortSignal.timeout(120000),
    });
  },
  async removePlaylist(id: string): Promise<void> {
    await request('/playlists/' + id, { method: 'DELETE' });
  },
  async detachTrack(playlistId: string, trackId: string): Promise<void> {
    await request(`/playlists/${playlistId}/tracks/${trackId}`, { method: 'DELETE' });
  },
  async attachTrack(playlistId: string, trackId: string): Promise<void> {
    await request(`/playlists/${playlistId}/tracks/${trackId}`, { method: 'PUT' });
  },
};
