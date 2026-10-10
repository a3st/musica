import { record, text } from '../../shared/api/validation';
import { t } from '../../shared/i18n';

export interface SearchTrack {
  external_id: string;
  title: string;
  artist: string;
  album: string | null;
  duration_seconds: number | null;
  artwork_url: string | null;
  store_url: string | null;
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
    if (!/^[1-9][0-9]{0,19}$/.test(id) || ids.has(id)) throw new Error(t('errors.invalidData'));
    ids.add(id);
    const duration = item.duration_seconds;
    if (
      duration !== null &&
      (typeof duration !== 'number' || !Number.isSafeInteger(duration) || duration < 0)
    )
      throw new Error(t('errors.invalidData'));
    return {
      external_id: id,
      title: text(item.title),
      artist: text(item.artist),
      album: item.album === null ? null : text(item.album),
      duration_seconds: duration,
      artwork_url: secureUrl(item.artwork_url),
      store_url: secureUrl(item.store_url),
    };
  });
}
