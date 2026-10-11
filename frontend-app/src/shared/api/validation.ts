import { t } from '../i18n';

/** Проверяет JSON-объект без массивов и null. */
export function record(data: unknown): Record<string, unknown> {
  if (typeof data !== 'object' || data === null || Array.isArray(data))
    throw new Error(t('errors.invalidData'));

  return data as Record<string, unknown>;
}

/** Проверяет строковое поле ответа без преобразования других типов. */
export function text(data: unknown): string {
  if (typeof data !== 'string') throw new Error(t('errors.invalidText'));

  return data;
}

/** Проверяет строковое представление UUID. */
export function uuid(data: unknown): string {
  const id = text(data);
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id))
    throw new Error(t('errors.invalidId'));

  return id;
}

/** Принимает строку или явно заданный null. */
export function nullableText(data: unknown): string | null {
  return data === null ? null : text(data);
}

/** Проверяет булево поле ответа. */
export function bool(data: unknown): boolean {
  if (typeof data !== 'boolean') throw new Error(t('errors.invalidResponse'));

  return data;
}

/** Принимает безопасное неотрицательное целое либо null. */
export function nullableNonNegativeInteger(data: unknown): number | null {
  if (data === null) return null;

  if (typeof data !== 'number' || !Number.isSafeInteger(data) || data < 0)
    throw new Error(t('errors.invalidData'));

  return data;
}

/** Проверяет строковое значение по списку допустимых вариантов. */
export function choice<T extends string>(data: unknown, values: readonly T[]): T {
  if (typeof data !== 'string' || !values.includes(data as T))
    throw new Error(t('errors.unknownValue'));

  return data as T;
}
