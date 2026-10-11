/** Читает общий язык, включая другой dev-порт на том же хосте. */
export function readLanguage(): 'ru-RU' | 'en-US' | null {
  const value = document.cookie
    .split('; ')
    .find((part) => part.startsWith('musica_locale='))
    ?.split('=')[1];
  return value === 'ru-RU' || value === 'en-US' ? value : null;
}

/** Сохраняет несекретную настройку языка для обоих приложений на одном хосте. */
export function writeLanguage(locale: 'ru-RU' | 'en-US'): void {
  try {
    document.cookie = `musica_locale=${locale}; Path=/; Max-Age=31536000; SameSite=Lax${location.protocol === 'https:' ? '; Secure' : ''}`;
  } catch {
    // Настройка остаётся доступна в памяти при запрете cookies.
  }
}
