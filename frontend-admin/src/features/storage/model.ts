/** Размеры исходников из БД; HLS и изображения не включены в байтовые суммы. */
export interface Storage {
  source_bytes: number;
  user_bytes: number;
  system_bytes: number;
  orphaned_bytes: number;
  tracks: number;
  orphaned_tracks: number;
  pending_tracks: number;
  hls_segments: number;
  cleanup_jobs: number;
}

/** Проверяет все счётчики ответа, запрещая отрицательные и небезопасные числа. */
export function parseStorage(data: unknown): Storage {
  const keys = [
    'source_bytes',
    'user_bytes',
    'system_bytes',
    'orphaned_bytes',
    'tracks',
    'orphaned_tracks',
    'pending_tracks',
    'hls_segments',
    'cleanup_jobs',
  ] as const;
  if (typeof data !== 'object' || data === null) throw new Error('Invalid storage response');
  const result = {} as Storage;

  for (const key of keys) {
    const value = (data as Record<string, unknown>)[key];
    if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0)
      throw new Error('Invalid storage counter');
    result[key] = value;
  }
  return result;
}

/** Показывает объём в двоичных единицах без фиктивной ёмкости диска. */
export function formatBytes(bytes: number, locale: string): string {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  const index = bytes === 0 ? 0 : Math.min(4, Math.floor(Math.log(bytes) / Math.log(1024)));
  return `${new Intl.NumberFormat(locale, { maximumFractionDigits: 1 }).format(bytes / 1024 ** index)} ${units[index]}`;
}
