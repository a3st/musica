export type TrackStatus = 'pending' | 'ready' | 'streamed';
export interface Track { id: string; title: string; artist: string; status: TrackStatus; owner_id: string | null }
export interface PlaylistSummary { id: string; owner_id: string; title: string; description: string; visibility: 'private' | 'public' | 'unlisted'; is_default: boolean; image_key: string | null; role: 'owner' | 'editor' | 'viewer'; track_count: number }
export interface Playlist { id: string; owner_id: string; title: string; description: string; visibility: PlaylistSummary['visibility']; is_default: boolean; image_key: string | null; tracks: Track[] }
export interface User { id: string; username: string; default_playlist_id: string }
export interface HlsState { status: TrackStatus; preparation: 'queued' | 'processing' | 'completed' | 'failed' | null }

export class ApiError extends Error {
  constructor(public readonly status: number, public readonly code: string) { super(code); }
}
function record(data: unknown): Record<string, unknown> {
  if (typeof data !== 'object' || data === null || Array.isArray(data)) throw new Error('Сервер вернул некорректные данные');
  return data as Record<string, unknown>;
}
function text(data: unknown): string { if (typeof data !== 'string') throw new Error('Некорректный текст в ответе'); return data; }
function uuid(data: unknown): string {
  const id = text(data);
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) throw new Error('Некорректный ID в ответе');
  return id;
}
function nullableText(data: unknown): string | null { return data === null ? null : text(data); }
function bool(data: unknown): boolean { if (typeof data !== 'boolean') throw new Error('Некорректный ответ'); return data; }
function choice<T extends string>(data: unknown, values: readonly T[]): T {
  if (typeof data !== 'string' || !values.includes(data as T)) throw new Error('Неизвестное значение в ответе');
  return data as T;
}
function track(data: unknown): Track {
  const r = record(data);
  return { id: uuid(r.id), title: text(r.title), artist: text(r.artist), status: choice(r.status, ['pending', 'ready', 'streamed']), owner_id: r.owner_id === null ? null : uuid(r.owner_id) };
}
function metadata(data: unknown) {
  const r = record(data);
  return { id: uuid(r.id), owner_id: uuid(r.owner_id), title: text(r.title), description: text(r.description), visibility: choice(r.visibility, ['private', 'public', 'unlisted'] as const), is_default: bool(r.is_default), image_key: nullableText(r.image_key) };
}
export async function request(path: string, init: RequestInit = {}): Promise<unknown> {
  const response = await fetch('/api' + path, { credentials: 'same-origin', cache: 'no-store', signal: AbortSignal.timeout(30000), ...init });
  if (response.status === 204) return null;
  const data: unknown = await response.json().catch(() => { throw new Error('Сервер вернул некорректный ответ. Попробуйте позже.'); });
  if (!response.ok) throw new ApiError(response.status, typeof record(data).error === 'string' ? text(record(data).error) : 'request_failed');
  return data;
}
const json = (body: unknown): RequestInit => ({ headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
export const api = {
  async me(): Promise<User> { const r = record(await request('/users/me')); return { id: uuid(r.id), username: text(r.username), default_playlist_id: uuid(r.default_playlist_id) }; },
  async signIn(username: string, password: string, register: boolean): Promise<void> {
    const r = record(await request(register ? '/auth/register' : '/auth/login', { method: 'POST', ...json({ username, password }) }));
    uuid(r.user_id);
  },
  async logout(): Promise<void> { await request('/auth/logout', { method: 'POST' }); },
  async playlists(): Promise<PlaylistSummary[]> {
    const data = await request('/playlists');
    if (!Array.isArray(data)) throw new Error('Некорректный список плейлистов');
    return data.map((item: unknown) => { const r = record(item); const count = r.track_count;
      if (typeof count !== 'number' || !Number.isSafeInteger(count) || count < 0) throw new Error('Некорректное количество треков');
      return { ...metadata(item), role: choice(r.role, ['owner', 'editor', 'viewer'] as const), track_count: count };
    });
  },
  async playlist(id: string): Promise<Playlist> {
    const data = await request('/playlists/' + id); const r = record(data);
    if (!Array.isArray(r.tracks)) throw new Error('Некорректный список треков');
    return { ...metadata(data), tracks: r.tracks.map(track) };
  },
  async createPlaylist(title: string, description: string, visibility: Playlist['visibility']): Promise<string> {
    return uuid(record(await request('/playlists', { method: 'POST', ...json({ title, description, visibility }) })).id);
  },
  async createTrack(title: string, artist: string, playlistIds: string[]): Promise<string> {
    return uuid(record(await request('/tracks', { method: 'POST', ...json({ title, artist, playlist_ids: playlistIds }) })).id);
  },
  async removePlaylist(id: string): Promise<void> { await request('/playlists/' + id, { method: 'DELETE' }); },
  async prepare(id: string): Promise<HlsState> { return hlsState(await request(`/tracks/${id}/hls`, { method: 'POST' })); },
  async preparation(id: string): Promise<HlsState> { return hlsState(await request(`/tracks/${id}/hls/status`)); },
  async removeTrack(id: string): Promise<void> { await request('/tracks/' + id, { method: 'DELETE' }); },
  async detachTrack(playlistId: string, trackId: string): Promise<void> { await request(`/playlists/${playlistId}/tracks/${trackId}`, { method: 'DELETE' }); },
  async attachTrack(playlistId: string, trackId: string): Promise<void> { await request(`/playlists/${playlistId}/tracks/${trackId}`, { method: 'PUT' }); },
};
function hlsState(data: unknown): HlsState {
  const r = record(data);
  return { status: choice(r.status, ['pending', 'ready', 'streamed']), preparation: r.preparation === null ? null : choice(r.preparation, ['queued', 'processing', 'completed', 'failed'] as const) };
}
export function uploadFile(id: string, file: File, progress: (percent: number) => void, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    const abort = () => xhr.abort();
    xhr.open('PUT', `/api/tracks/${id}/file`);
    xhr.withCredentials = true;
    xhr.timeout = 120000;
    const mime = file.name.toLowerCase().endsWith('.mp3') ? 'audio/mpeg' : file.type || 'application/octet-stream';
    xhr.setRequestHeader('Content-Type', mime);
    xhr.upload.onprogress = (event) => { if (event.lengthComputable) progress(Math.round(event.loaded / event.total * 100)); };
    const finish = () => signal.removeEventListener('abort', abort);
    xhr.onload = () => {
      finish();
      if (xhr.status >= 200 && xhr.status < 300) resolve();
      else { let code = 'upload_failed'; try { code = text(record(JSON.parse(xhr.responseText) as unknown).error); } catch { /* Keep generic message. */ } reject(new ApiError(xhr.status, code)); }
    };
    xhr.onerror = () => { finish(); reject(new Error('Не удалось загрузить файл. Проверьте соединение.')); };
    xhr.ontimeout = () => { finish(); reject(new Error('Сервер не завершил загрузку вовремя')); };
    xhr.onabort = () => { finish(); reject(new DOMException('Загрузка отменена', 'AbortError')); };
    signal.addEventListener('abort', abort, { once: true });
    if (signal.aborted) { finish(); reject(new DOMException('Загрузка отменена', 'AbortError')); return; }
    xhr.send(file);
  });
}
export function errorMessage(error: unknown): string {
  if (error instanceof ApiError) {
    const messages: Record<string, string> = { unauthorized: 'Войдите в аккаунт', invalid_credentials: 'Имя: 3–64 символа a–z, цифры или _. Пароль: от 12 символов.', conflict: 'Это имя пользователя уже занято', invalid_track_metadata: 'Название и исполнитель должны содержать от 1 до 256 символов', file_too_large: 'Файл превышает лимит сервера', track_preparation_in_progress: 'Трек ещё готовится. Попробуйте удалить его после завершения.', upload_in_progress: 'Загрузка этого трека ещё не завершена', not_found: 'Объект не найден или доступ отозван', track_not_found: 'Трек не найден или доступ отозван', internal_error: 'Не удалось выполнить запрос. Попробуйте позже.', hls_not_ready: 'Трек ещё готовится к воспроизведению' };
    return messages[error.code] ?? `Не удалось выполнить запрос (${error.status})`;
  }
  if (error instanceof Error) return error.name === 'TimeoutError' ? 'Сервер не ответил вовремя. Попробуйте ещё раз.' : error.name === 'TypeError' ? 'Не удаётся подключиться к серверу' : error.message;
  return 'Не удалось выполнить действие';
}
