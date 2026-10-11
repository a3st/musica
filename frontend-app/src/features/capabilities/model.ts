import { bool, record } from '../../shared/api/validation';

export interface Capabilities {
  web_search: boolean;
  spotify_import: boolean;
}

/** Проверяет итоговые возможности сервера до использования в интерфейсе. */
export function capabilities(value: unknown): Capabilities {
  const result = record(value);
  return {
    web_search: bool(result.web_search),
    spotify_import: bool(result.spotify_import),
  };
}
