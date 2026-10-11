/** Читает настройку; недоступный localStorage трактуется как отсутствие значения. */
export function readPreference(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

/** Сохраняет настройку; при недоступном localStorage приложение продолжает работу. */
export function writePreference(key: string, value: string): void {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* Preferences remain usable in memory. */
  }
}
