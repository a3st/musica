/** HTTP-ошибка с безопасным машинным кодом сервера. */
export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
  ) {
    super(code);
  }
}

/** Выполняет запрос с HttpOnly cookie, без кеша; принимает отмену от состояния фичи. */
export async function request(path: string, init: RequestInit = {}): Promise<unknown> {
  const response = await fetch(`/api${path}`, {
    credentials: 'same-origin',
    cache: 'no-store',
    ...init,
    signal: init.signal
      ? AbortSignal.any([init.signal, AbortSignal.timeout(30000)])
      : AbortSignal.timeout(30000),
  });
  if (response.status === 204) return null;

  const data: unknown = await response.json();
  if (!response.ok) {
    const code =
      typeof data === 'object' && data !== null && 'error' in data && typeof data.error === 'string'
        ? data.error
        : 'request_failed';
    throw new ApiError(response.status, code);
  }
  return data;
}

/** Формирует JSON-тело запроса; чувствительные поля не сохраняются локально. */
export function json(body: unknown): RequestInit {
  return { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) };
}
