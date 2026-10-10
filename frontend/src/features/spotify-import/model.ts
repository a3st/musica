import { record, text, uuid, nullableText, bool, choice } from '../../shared/api/validation';
import { t } from '../../shared/i18n';
import type { TrackStatus, HlsState } from '../tracks/model';
export interface SpotifyImportStatus {
  id: string;
  tracks: {
    id: string;
    title: string;
    artist: string;
    download: 'queued' | 'processing' | 'completed' | 'failed';
    status: TrackStatus | null;
    preparation: HlsState['preparation'];
  }[];
}

export function spotifyStatus(data: unknown): SpotifyImportStatus {
  const r = record(data);
  if (!Array.isArray(r.tracks)) throw new Error(t('errors.invalidImportStatus'));
  return {
    id: uuid(r.id),
    tracks: r.tracks.map((value: unknown) => {
      const t = record(value);
      return {
        id: uuid(t.id),
        title: text(t.title),
        artist: text(t.artist),
        download: choice(t.download, ['queued', 'processing', 'completed', 'failed'] as const),
        status:
          t.status === null ? null : choice(t.status, ['pending', 'ready', 'streamed'] as const),
        preparation:
          t.preparation === null
            ? null
            : choice(t.preparation, ['queued', 'processing', 'completed', 'failed'] as const),
      };
    }),
  };
}
