import { webSearchApi } from './api';
import type { Track } from '../tracks/model';
import { t } from '../../shared/i18n';

/** Ждёт загрузки общего трека без привязки к Uploads; отменяется при смене воспроизведения. */
export async function waitForDownloadedTrack(id: string, signal: AbortSignal): Promise<Track> {
  const deadline = Date.now() + 15 * 60 * 1000;
  while (Date.now() < deadline) {
    signal.throwIfAborted();
    const state = await webSearchApi.playback(id, signal);
    const track = state.track;
    if (track.status !== 'pending') return track;
    if (state.download === 'failed' || state.download === null)
      throw new Error(t('web.trackUnavailable'));
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
