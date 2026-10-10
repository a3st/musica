import { record, text, uuid } from '../../shared/api/validation';
import { request, json } from '../../shared/api/client';
import type { User } from './model';
export const authApi = {
  async me(): Promise<User> {
    const r = record(await request('/users/me'));
    return {
      id: uuid(r.id),
      username: text(r.username),
      default_playlist_id: uuid(r.default_playlist_id),
    };
  },
  async signIn(username: string, password: string, register: boolean): Promise<void> {
    const r = record(
      await request(register ? '/auth/register' : '/auth/login', {
        method: 'POST',
        ...json({ username, password }),
      }),
    );
    uuid(r.user_id);
  },
  async logout(): Promise<void> {
    await request('/auth/logout', { method: 'POST' });
  },
};
