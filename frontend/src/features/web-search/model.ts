import { record, text } from '../../shared/api/validation';
import { t } from '../../shared/i18n';

export interface SearchTrack {
  provider: 'itunes';
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
    if (item.provider !== 'itunes' || !/^[1-9][0-9]{0,19}$/.test(id))
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
