import { record, text } from '../../shared/api/validation';
import { t } from '../../shared/i18n';
import { track, type Track } from '../tracks/model';

export interface SearchResult {
  library: Track[];
  catalog: SearchTrack[];
}

export interface SearchTrack {
  provider: 'itunes' | 'deezer';
  external_id: string;
  title: string;
  artist: string;
  album: string | null;
  artwork_url: string | null;
  source_url: string | null;
}

export function searchTrackKey(track: Pick<SearchTrack, 'provider' | 'external_id'>): string {
  return `${track.provider}:${track.external_id}`;
}

function secureUrl(value: unknown): string | null {
  if (value === null) return null;
  const url = new URL(text(value));
  if (url.protocol !== 'https:' || url.username || url.password)
    throw new Error(t('errors.invalidData'));
  return url.href;
}

/** Проверяет ответ каталога до отображения внешних метаданных и ссылок. */
export function parseSearchTracks(value: unknown): SearchTrack[] {
  const rows = record(value).tracks;
  if (!Array.isArray(rows)) throw new Error(t('errors.invalidData'));
  const ids = new Set<string>();
  return rows.map((row) => {
    const item = record(row);
    const id = text(item.external_id);
    if (
      (item.provider !== 'itunes' && item.provider !== 'deezer') ||
      !/^[1-9][0-9]{0,19}$/.test(id)
    )
      throw new Error(t('errors.invalidData'));
    const key = searchTrackKey({ provider: item.provider, external_id: id });
    if (ids.has(key)) throw new Error(t('errors.invalidData'));
    ids.add(key);
    return {
      provider: item.provider,
      external_id: id,
      title: text(item.title),
      artist: text(item.artist),
      album: item.album === null ? null : text(item.album),
      artwork_url: secureUrl(item.artwork_url),
      source_url: secureUrl(item.source_url),
    };
  });
}

/** Проверяет готовые сервисные треки и дополнительные внешние результаты до отображения. */
export function parseSearchResult(value: unknown): SearchResult {
  const result = record(value);
  if (!Array.isArray(result.library) || result.library.length > 25)
    throw new Error(t('errors.invalidData'));
  const ids = new Set<string>();
  const library = result.library.map((value) => {
    const item = track(value);
    if (item.owner_kind !== 'system' || item.status === 'pending' || ids.has(item.id))
      throw new Error(t('errors.invalidData'));
    ids.add(item.id);
    return item;
  });
  return { library, catalog: parseSearchTracks({ tracks: result.catalog }) };
}
