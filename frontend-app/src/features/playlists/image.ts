import type { Playlist } from './model';

/** Формирует URL обложки с версией для обновления изображения после замены. */
export function playlistImageUrl(playlist: Pick<Playlist, 'id' | 'image_key'>): string {
  return `/api/playlists/${playlist.id}/image?v=${encodeURIComponent(playlist.image_key ?? '')}`;
}
