import { record, text, uuid, nullableText, bool, choice } from '../../shared/api/validation';
import { t } from '../../shared/i18n';
export type TrackStatus = 'pending' | 'ready' | 'streamed';

export interface Track {
  id: string;
  title: string;
  artist: string;
  status: TrackStatus;
  owner_id: string | null;
}

export interface HlsState {
  status: TrackStatus;
  preparation: 'queued' | 'processing' | 'completed' | 'failed' | null;
}

export function track(data: unknown): Track {
  const r = record(data);
  return {
    id: uuid(r.id),
    title: text(r.title),
    artist: text(r.artist),
    status: choice(r.status, ['pending', 'ready', 'streamed']),
    owner_id: r.owner_id === null ? null : uuid(r.owner_id),
  };
}

export function hlsState(data: unknown): HlsState {
  const r = record(data);
  return {
    status: choice(r.status, ['pending', 'ready', 'streamed']),
    preparation:
      r.preparation === null
        ? null
        : choice(r.preparation, ['queued', 'processing', 'completed', 'failed'] as const),
  };
}
