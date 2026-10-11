import { record, text, uuid, choice } from '../../shared/api/validation';
import { t } from '../../shared/i18n';
import { request, json } from '../../shared/api/client';
import { playlist, metadata, type Playlist, type PlaylistSummary } from './model';

export const playlistsApi = {
  /** Получает доступные плейлисты и проверяет их роли и количество треков. */
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

  /** Получает плейлист по ID; объединяет отмену вызывающего кода с таймаутом. */
  async playlist(id: string, signal?: AbortSignal): Promise<Playlist> {
    return playlist(
      await request('/playlists/' + id, {
        signal: signal
          ? AbortSignal.any([signal, AbortSignal.timeout(30000)])
          : AbortSignal.timeout(30000),
      }),
    );
  },

  /** Получает плейлист по токену доступа из ссылки. */
  async sharedPlaylist(token: string): Promise<Playlist> {
    return playlist(await request('/shared/playlists/' + encodeURIComponent(token)));
  },

  /** Создаёт ссылку доступа и проверяет возвращённый сервером токен. */
  async createShareLink(id: string): Promise<string> {
    const path = text(
      record(await request(`/playlists/${id}/share-link`, { method: 'POST' })).path,
    );
    const token = /^\/api\/shared\/playlists\/([0-9a-f]{64})$/.exec(path)?.[1];
    if (!token) throw new Error(t('errors.invalidResponse'));

    return token;
  },

  /** Создаёт плейлист и возвращает проверенный UUID. */
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

  /** Обновляет текстовые данные, видимость и теги плейлиста. */
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

  /** Загружает обложку с MIME-типом файла и увеличенным таймаутом. */
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

  /** Удаляет плейлист; права и защиту Uploads проверяет сервер. */
  async removePlaylist(id: string): Promise<void> {
    await request('/playlists/' + id, { method: 'DELETE' });
  },

  /** Удаляет связь трека с плейлистом. */
  async detachTrack(playlistId: string, trackId: string): Promise<void> {
    await request(`/playlists/${playlistId}/tracks/${trackId}`, { method: 'DELETE' });
  },

  /** Добавляет существующий трек в плейлист. */
  async attachTrack(playlistId: string, trackId: string): Promise<void> {
    await request(`/playlists/${playlistId}/tracks/${trackId}`, { method: 'PUT' });
  },
};
