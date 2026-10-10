import { request } from '../../shared/api/client';
import { capabilities } from './model';

export const capabilitiesApi = {
  async read() {
    return capabilities(await request('/capabilities', { signal: AbortSignal.timeout(10000) }));
  },
};
