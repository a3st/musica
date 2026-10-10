import { record, text, uuid, nullableText, bool, choice } from '../../shared/api/validation';
import { t } from '../../shared/i18n';
import { track, type Track } from '../tracks/model';
export interface PlaylistSummary {
  id: string;
  owner_id: string;
  title: string;
  description: string;
  tags?: string[];
  visibility: 'private' | 'public' | 'unlisted';
  is_default: boolean;
  image_key: string | null;
  role: 'owner' | 'editor' | 'viewer';
  track_count: number;
}

export interface Playlist {
  id: string;
  owner_id: string;
  title: string;
  description: string;
  tags?: string[];
  visibility: PlaylistSummary['visibility'];
  is_default: boolean;
  image_key: string | null;
  tracks: Track[];
}

export function metadata(data: unknown) {
  const r = record(data);
  if (r.tags !== undefined && !Array.isArray(r.tags)) throw new Error(t('errors.invalidResponse'));
  return {
    id: uuid(r.id),
    owner_id: uuid(r.owner_id),
    title: text(r.title),
    description: text(r.description),
    tags: r.tags === undefined ? [] : (r.tags as unknown[]).map(text),
    visibility: choice(r.visibility, ['private', 'public', 'unlisted'] as const),
    is_default: bool(r.is_default),
    image_key: nullableText(r.image_key),
  };
}

export function playlist(data: unknown): Playlist {
  const r = record(data);
  if (!Array.isArray(r.tracks)) throw new Error(t('errors.invalidTrackList'));
  return { ...metadata(data), tracks: r.tracks.map(track) };
}
