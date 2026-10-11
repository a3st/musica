export type Color = readonly [number, number, number];

/** Выбирает частый насыщенный цвет, исключая влияние чёрных и белых краёв обложки. */
export function artworkColor(pixels: Uint8ClampedArray): Color | null {
  const buckets = new Map<string, { weight: number; sum: number[] }>();

  for (let index = 0; index < pixels.length; index += 4) {
    const color = [pixels[index], pixels[index + 1], pixels[index + 2]];
    const high = Math.max(...color);
    const low = Math.min(...color);
    if (pixels[index + 3] < 128 || high < 24 || low > 235) continue;
    const weight = 0.2 + (high - low) / 255;
    const key = color.map((channel) => Math.floor(channel / 32)).join(':');
    const bucket = buckets.get(key) ?? { weight: 0, sum: [0, 0, 0] };
    bucket.weight += weight;
    color.forEach((channel, component) => (bucket.sum[component] += channel * weight));
    buckets.set(key, bucket);
  }

  const best = [...buckets.values()].sort((a, b) => b.weight - a.weight)[0];

  return best
    ? (best.sum.map((channel) => Math.round(channel / best.weight)) as unknown as Color)
    : null;
}

/** Читает цвет через небольшой canvas; приватные обложки не сохраняются в хранилище. */
export function readArtworkColor(url: string, signal: AbortSignal): Promise<Color | null> {
  return new Promise((resolve) => {
    if (signal.aborted) {
      resolve(null);
      return;
    }
    const image = new Image();

    /** Освобождает слушатели и источник изображения перед завершением чтения. */
    function finish(color: Color | null): void {
      signal.removeEventListener('abort', abort);
      image.onload = null;
      image.onerror = null;
      image.src = '';
      resolve(color);
    }
    /** Завершает отменённое чтение без цвета и без ошибки для интерфейса. */
    function abort(): void {
      finish(null);
    }
    signal.addEventListener('abort', abort, { once: true });
    image.onload = () => {
      try {
        const canvas = document.createElement('canvas');
        canvas.width = canvas.height = 24;
        const context = canvas.getContext('2d', { willReadFrequently: true });
        if (!context) {
          finish(null);
          return;
        }
        context.drawImage(image, 0, 0, 24, 24);
        finish(artworkColor(context.getImageData(0, 0, 24, 24).data));
      } catch {
        finish(null);
      }
    };
    image.onerror = () => finish(null);
    image.src = url;
  });
}
