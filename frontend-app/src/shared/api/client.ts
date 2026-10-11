import { t } from '../i18n';
import { ApiError } from './errors';
import { record, text } from './validation';

/** Выполняет запрос к /api с cookie и без кеша; проверку данных выполняет вызывающая фича. */
export async function request(path: string, init: RequestInit = {}): Promise<unknown> {
  const response = await fetch('/api' + path, {
    credentials: 'same-origin',
    cache: 'no-store',
    signal: AbortSignal.timeout(30000),
    ...init,
  });
  if (response.status === 204) return null;

  const data: unknown = await response.json().catch(() => {
    throw new Error(t('errors.invalidServerResponse'));
  });
  if (!response.ok)
    throw new ApiError(
      response.status,
      typeof record(data).error === 'string' ? text(record(data).error) : 'request_failed',
    );

  return data;
}

/** Формирует JSON-тело и заголовок для параметров запроса. */
export const json = (body: unknown): RequestInit => ({
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
});
