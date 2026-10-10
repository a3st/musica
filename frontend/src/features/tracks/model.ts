import {
  record,
  text,
  uuid,
  nullableText,
  choice,
  nullableNonNegativeInteger,
} from '../../shared/api/validation';
import { t } from '../../shared/i18n';
export type TrackStatus = 'pending' | 'ready' | 'streamed';

export type OwnerKind = 'user' | 'system';

export interface Track {
  id: string;
  title: string;
  artist: string;
  status: TrackStatus;
  owner_id: string | null;
  owner_kind: OwnerKind | null;
  duration_seconds?: number | null;
  artwork_key?: string | null;
}

export interface HlsState {
  status: TrackStatus;
  preparation: 'queued' | 'processing' | 'completed' | 'failed' | null;
}

export function track(data: unknown): Track {
  const r = record(data);
  const ownerId = r.owner_id === null ? null : uuid(r.owner_id);
  const ownerKind =
    r.owner_kind === null ? null : choice(r.owner_kind, ['user', 'system'] as const);
  if ((ownerId === null) !== (ownerKind === null)) throw new Error(t('errors.invalidData'));

  return {
    id: uuid(r.id),
    title: text(r.title),
    artist: text(r.artist),
    status: choice(r.status, ['pending', 'ready', 'streamed']),
    owner_id: ownerId,
    owner_kind: ownerKind,
    duration_seconds: nullableNonNegativeInteger(r.duration_seconds ?? null),
    artwork_key: r.artwork_key === undefined ? null : nullableText(r.artwork_key),
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
