import { record, text, uuid } from '../../shared/api/validation';
import { request } from '../../shared/api/client';
import type { User } from './model';

export const authApi = {
  /** Получает текущего пользователя и проверяет обязательные поля ответа. */
  async me(signal?: AbortSignal): Promise<User> {
    const r = record(
      await request(
        '/users/me',
        signal
          ? {
              signal: AbortSignal.any([signal, AbortSignal.timeout(30000)]),
            }
          : {},
      ),
    );
    return {
      id: uuid(r.id),
      username: text(r.username),
      default_playlist_id: uuid(r.default_playlist_id),
    };
  },

  /** Завершает текущую серверную сессию. */
  async logout(): Promise<void> {
    await request('/auth/logout', { method: 'POST' });
  },
};
