import { json, request } from '../../shared/api/client';
import { record, uuid } from '../../shared/api/validation';
import { parseSearchTracks } from './model';

export const webSearchApi = {
  async search(query: string, signal: AbortSignal) {
    return parseSearchTracks(
      await request('/web/search?q=' + encodeURIComponent(query), {
        signal: AbortSignal.any([signal, AbortSignal.timeout(30000)]),
      }),
    );
  },

  async add(externalId: string, signal: AbortSignal): Promise<string> {
    const result = await request('/web/tracks', {
      method: 'POST',
      ...json({ external_id: externalId }),
      signal: AbortSignal.any([signal, AbortSignal.timeout(30000)]),
    });
    return uuid(record(result).id);
  },
};
