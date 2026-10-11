/** Разрешает возврат только внутрь настроенного плеера, исключая внешние редиректы. */
export function validateReturnUrl(candidate: string | null, player: string): string | null {
  if (!candidate) return null;

  try {
    const base = new URL(player);
    const url = new URL(candidate, base);
    const path = base.pathname.endsWith('/') ? base.pathname : `${base.pathname}/`;
    if (
      !['http:', 'https:'].includes(url.protocol) ||
      url.username ||
      url.password ||
      url.origin !== base.origin ||
      !(url.pathname === base.pathname || url.pathname.startsWith(path)) ||
      /^\/profile(?:\/|$)/.test(url.pathname)
    )
      return null;

    return url.href;
  } catch {
    return null;
  }
}
