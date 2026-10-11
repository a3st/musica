import { request } from '../../shared/api/client';

/** Читает публичную настройку регистрации; отсутствие флага запрещает кнопку регистрации. */
export async function readRegistration(signal: AbortSignal): Promise<boolean> {
  const value = await request('/capabilities', { signal });
  if (typeof value !== 'object' || value === null) throw new Error('Invalid capabilities');
  return 'registration_enabled' in value && value.registration_enabled === true;
}
