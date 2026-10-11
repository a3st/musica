import {
  record,
  text,
  uuid,
  nullableText,
  bool,
  choice,
  nullableNonNegativeInteger,
} from '../../shared/api/validation';
import { t } from '../../shared/i18n';
import { track, type Track } from '../tracks/model';

export interface PlaylistSummary {
  cover_tracks?: Pick<Track, 'id' | 'artwork_key'>[];
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
  duration_seconds?: number | null;
  duration_complete?: boolean;
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
  duration_seconds?: number | null;
  duration_complete?: boolean;
}

/** Проверяет общие поля плейлиста, данные обложки и длительность. */
export function metadata(data: unknown) {
  const r = record(data);
  const covers = r.cover_tracks ?? [];
  if (!Array.isArray(covers) || covers.length > 4) throw new Error(t('errors.invalidResponse'));

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
    cover_tracks: covers.map((value: unknown) => {
      const item = record(value);
      return { id: uuid(item.id), artwork_key: nullableText(item.artwork_key) };
    }),
    duration_seconds: nullableNonNegativeInteger(r.duration_seconds ?? null),
    duration_complete: r.duration_complete === undefined ? false : bool(r.duration_complete),
  };
}

/** Проверяет плейлист вместе с вложенным списком треков. */
export function playlist(data: unknown): Playlist {
  const r = record(data);
  if (!Array.isArray(r.tracks)) throw new Error(t('errors.invalidTrackList'));

  return { ...metadata(data), tracks: r.tracks.map(track) };
}
