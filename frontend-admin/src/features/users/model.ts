import { parseUser, type User } from '../auth/model';

/** Пользователь в списке администратора без пароля и токенов. */
export interface RegisteredUser extends User {
  created_at: string;
  tracks: number;
}

/** Проверяет список зарегистрированных аккаунтов во время выполнения. */
export function parseUsers(data: unknown): RegisteredUser[] {
  if (!Array.isArray(data)) throw new Error('Invalid users response');
  return data.map((item: unknown) => {
    const user = parseUser(item);
    const fields = item as Record<string, unknown>;
    if (
      typeof fields.created_at !== 'string' ||
      !Number.isFinite(Date.parse(fields.created_at)) ||
      typeof fields.tracks !== 'number' ||
      !Number.isSafeInteger(fields.tracks) ||
      fields.tracks < 0
    ) {
      throw new Error('Invalid user counters');
    }
    return { ...user, created_at: fields.created_at, tracks: fields.tracks };
  });
}
