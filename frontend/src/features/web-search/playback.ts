import { playlistsApi } from '../playlists/api';
import type { Track } from '../tracks/model';
import { t } from '../../shared/i18n';

/** Ждёт появления загруженного файла в Uploads; отменяется при смене воспроизведения. */
export async function waitForDownloadedTrack(
  id: string,
  uploadsId: string,
  signal: AbortSignal,
): Promise<Track> {
  const deadline = Date.now() + 15 * 60 * 1000;
  while (Date.now() < deadline) {
    signal.throwIfAborted();
    const playlist = await playlistsApi.playlist(uploadsId, signal);
    const track = playlist.tracks.find((item) => item.id === id);
    if (!track) throw new Error(t('web.trackUnavailable'));
    if (track.status !== 'pending') return track;
    await new Promise<void>((resolve, reject) => {
      const abort = () => {
        clearTimeout(timer);
        reject(signal.reason);
      };
      const timer = setTimeout(() => {
        signal.removeEventListener('abort', abort);
        resolve();
      }, 2000);
      signal.addEventListener('abort', abort, { once: true });
      if (signal.aborted) abort();
    });
  }
  throw new Error(t('web.downloadTimeout'));
}
