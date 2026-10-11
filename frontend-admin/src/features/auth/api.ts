import { json, request } from '../../shared/api/client';
import { parseUser, type User } from './model';

export const authApi = {
  /** Получает профиль и роль текущего пользователя, поддерживая отмену запроса. */
  async me(signal?: AbortSignal): Promise<User> {
    return parseUser(await request('/users/me', { ...(signal ? { signal } : {}) }));
  },

  /** Создаёт серверную сессию; токен не сохраняется в JavaScript-хранилищах. */
  async login(username: string, password: string): Promise<void> {
    await request('/auth/login', { method: 'POST', ...json({ username, password }) });
  },

  /** Завершает текущую серверную сессию. */
  async logout(): Promise<void> {
    await request('/auth/logout', { method: 'POST' });
  },
};
