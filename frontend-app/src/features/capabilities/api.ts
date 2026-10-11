import { request } from '../../shared/api/client';
import { capabilities } from './model';

export const capabilitiesApi = {
  /** Получает проверенные возможности сервера с таймаутом десять секунд. */
  async read() {
    return capabilities(await request('/capabilities', { signal: AbortSignal.timeout(10000) }));
  },
};
