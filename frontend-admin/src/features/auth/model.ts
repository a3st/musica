/** Профиль текущей сессии; административные права всегда проверяет сервер. */
export interface User {
  id: string;
  username: string;
  role: 'user' | 'admin';
}

/** Проверяет профиль при получении JSON, включая роль. */
export function parseUser(data: unknown): User {
  if (
    typeof data !== 'object' ||
    data === null ||
    !('id' in data) ||
    !('username' in data) ||
    !('role' in data) ||
    typeof data.id !== 'string' ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(data.id) ||
    typeof data.username !== 'string' ||
    typeof data.role !== 'string' ||
    !['user', 'admin'].includes(data.role)
  ) {
    throw new Error('Invalid profile response');
  }
  return { id: data.id, username: data.username, role: data.role as User['role'] };
}
