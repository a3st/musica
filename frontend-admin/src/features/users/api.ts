import { request, json } from '../../shared/api/client';
import { parseUsers, type RegisteredUser } from './model';

export const usersApi = {
  /** Загружает список обычных аккаунтов для администратора. */
  async list(signal: AbortSignal): Promise<RegisteredUser[]> {
    return parseUsers(await request('/admin/users', { signal }));
  },

  /** Создаёт обычный аккаунт; пароль не сохраняется в клиентском хранилище. */
  async create(username: string, password: string): Promise<void> {
    await request('/admin/users', { method: 'POST', ...json({ username, password }) });
  },

  /** Удаляет подтверждённый аккаунт и его личные данные через backend. */
  async remove(id: string): Promise<void> {
    await request(`/admin/users/${encodeURIComponent(id)}`, { method: 'DELETE' });
  },
};
