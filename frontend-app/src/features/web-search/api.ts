import { json, request } from '../../shared/api/client';
import { record, uuid, choice } from '../../shared/api/validation';
import { track } from '../tracks/model';
import { parseSearchResult } from './model';
import type { SearchTrack } from './model';

export const webSearchApi = {
  /** Получает проверенную выдачу сервисных треков и каталога с отменой и таймаутом. */
  async search(query: string, signal: AbortSignal) {
    return parseSearchResult(
      await request('/web/search?q=' + encodeURIComponent(query), {
        signal: AbortSignal.any([signal, AbortSignal.timeout(30000)]),
      }),
    );
  },

  /** Создаёт или находит общий трек; добавление в личную библиотеку задаётся отдельно. */
  async add(
    selection: Pick<SearchTrack, 'provider' | 'external_id'>,
    signal: AbortSignal,
    addToLibrary = true,
  ): Promise<string> {
    const result = await request('/web/tracks', {
      method: 'POST',
      ...json({
        provider: selection.provider,
        external_id: selection.external_id,
        add_to_library: addToLibrary,
      }),
      signal: AbortSignal.any([signal, AbortSignal.timeout(30000)]),
    });
    return uuid(record(result).id);
  },

  /** Получает общий трек и состояние его скачивания с возможностью отмены. */
  async playback(id: string, signal: AbortSignal) {
    const result = record(await request('/web/tracks/' + uuid(id), { signal }));
    return {
      track: track(result.track),
      download:
        result.download === null
          ? null
          : choice(result.download, ['queued', 'processing', 'completed', 'failed'] as const),
    };
  },
};
