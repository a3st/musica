/** Возвращает адрес плеера: отдельный dev-порт или настроенный production URL. */
export function playerUrl(): string {
  const configured = import.meta.env.VITE_PLAYER_URL?.trim();
  if (configured) {
    try {
      const url = new URL(configured, window.location.origin);
      if ((url.protocol === 'http:' || url.protocol === 'https:') && !url.username && !url.password)
        return url.href;
    } catch {
      // Некорректная настройка не должна блокировать запуск админки.
    }
  }

  if (!import.meta.env.DEV) return '/';
  const url = new URL(window.location.origin);
  url.port = '5173';
  return url.href;
}
