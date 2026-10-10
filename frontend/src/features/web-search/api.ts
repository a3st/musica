import { json, request } from '../../shared/api/client';
import { record, uuid } from '../../shared/api/validation';
import { parseSearchTracks } from './model';
import type { SearchTrack } from './model';

export const webSearchApi = {
  async search(query: string, signal: AbortSignal) {
    return parseSearchTracks(
      await request('/web/search?q=' + encodeURIComponent(query), {
        signal: AbortSignal.any([signal, AbortSignal.timeout(30000)]),
      }),
    );
  },

  async add(
    selection: Pick<SearchTrack, 'provider' | 'external_id'>,
    signal: AbortSignal,
  ): Promise<string> {
    const result = await request('/web/tracks', {
      method: 'POST',
      ...json({ provider: selection.provider, external_id: selection.external_id }),
      signal: AbortSignal.any([signal, AbortSignal.timeout(30000)]),
    });
    return uuid(record(result).id);
  },
};
