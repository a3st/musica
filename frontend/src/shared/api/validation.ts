import { t } from '../i18n';
export function record(data: unknown): Record<string, unknown> {
  if (typeof data !== 'object' || data === null || Array.isArray(data))
    throw new Error(t('errors.invalidData'));
  return data as Record<string, unknown>;
}

export function text(data: unknown): string {
  if (typeof data !== 'string') throw new Error(t('errors.invalidText'));
  return data;
}

export function uuid(data: unknown): string {
  const id = text(data);
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id))
    throw new Error(t('errors.invalidId'));
  return id;
}

export function nullableText(data: unknown): string | null {
  return data === null ? null : text(data);
}

export function bool(data: unknown): boolean {
  if (typeof data !== 'boolean') throw new Error(t('errors.invalidResponse'));
  return data;
}

export function nullableNonNegativeInteger(data: unknown): number | null {
  if (data === null) return null;
  if (typeof data !== 'number' || !Number.isSafeInteger(data) || data < 0)
    throw new Error(t('errors.invalidData'));
  return data;
}

export function choice<T extends string>(data: unknown, values: readonly T[]): T {
  if (typeof data !== 'string' || !values.includes(data as T))
    throw new Error(t('errors.unknownValue'));
  return data as T;
}
