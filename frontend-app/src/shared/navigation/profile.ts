/** Возвращает адрес профиля; в production оба приложения используют один домен. */
export function profileUrl(returnToPlayer = false): string {
  const fallback = new URL('/profile/', window.location.origin);
  if (import.meta.env.DEV) fallback.port = '5174';

  const url = new URL(
    import.meta.env.VITE_PROFILE_URL?.trim() || fallback.href,
    window.location.origin,
  );
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password)
    throw new Error('Invalid VITE_PROFILE_URL');

  if (returnToPlayer) url.searchParams.set('return_to', window.location.href);
  else url.searchParams.delete('return_to');

  return url.href;
}
