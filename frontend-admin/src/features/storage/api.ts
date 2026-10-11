import { request } from '../../shared/api/client';
import { parseStorage, type Storage } from './model';

export const storageApi = {
  /** Получает статистику; сервер разрешает запрос только администраторам. */
  async read(signal?: AbortSignal): Promise<Storage> {
    return parseStorage(await request('/admin/storage', { ...(signal ? { signal } : {}) }));
  },

  /** Ставит удаление одного пакета orphaned-треков; проверяет счётчики результата. */
  async cleanup(): Promise<{ removed: number; skipped: number }> {
    const data = await request('/admin/storage/cleanup-orphaned', { method: 'POST' });
    if (
      typeof data !== 'object' ||
      data === null ||
      !('removed' in data) ||
      !('skipped' in data) ||
      typeof data.removed !== 'number' ||
      !Number.isSafeInteger(data.removed) ||
      data.removed < 0 ||
      typeof data.skipped !== 'number' ||
      !Number.isSafeInteger(data.skipped) ||
      data.skipped < 0
    ) {
      throw new Error('Invalid cleanup response');
    }
    return { removed: data.removed, skipped: data.skipped };
  },
};
