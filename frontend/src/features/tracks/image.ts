import type { Track } from './model';

/** Возвращает URL обложки через API с проверкой доступа на сервере. */
export function trackArtworkUrl(
  track: Pick<Track, 'id' | 'artwork_key'>,
  shareToken: string | null = null,
): string | null {
  if (!track.artwork_key) return null;

  const query = new URLSearchParams({ v: track.artwork_key });
  if (shareToken) query.set('share_token', shareToken);

  return `/api/tracks/${encodeURIComponent(track.id)}/artwork?${query}`;
}
