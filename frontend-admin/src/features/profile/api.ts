import { json, request } from '../../shared/api/client';

export const profileApi = {
  /** Меняет пароль; сервер отзывает все сессии после успешного изменения. */
  async changePassword(password: string, newPassword: string): Promise<void> {
    await request('/profile/password', {
      method: 'PUT',
      ...json({ password, new_password: newPassword }),
    });
  },

  /** Удаляет аккаунт после подтверждения текущим паролем. */
  async remove(password: string): Promise<void> {
    await request('/profile', { method: 'DELETE', ...json({ password }) });
  },
};
