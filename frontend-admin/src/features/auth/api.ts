import { json, request } from '../../shared/api/client';
import { parseUser, type User } from './model';

export const authApi = {
  /** Получает профиль и роль текущего пользователя, поддерживая отмену запроса. */
  async me(signal?: AbortSignal): Promise<User> {
    return parseUser(await request('/users/me', { ...(signal ? { signal } : {}) }));
  },

  /** Выполняет вход или регистрацию; токен сессии не сохраняется в JavaScript-хранилищах. */
  async signIn(username: string, password: string, register: boolean): Promise<void> {
    await request(register ? '/auth/register' : '/auth/login', {
      method: 'POST',
      ...json({ username, password }),
    });
  },

  /** Завершает текущую серверную сессию. */
  async logout(): Promise<void> {
    await request('/auth/logout', { method: 'POST' });
  },
};
