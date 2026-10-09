import { api, ApiError, errorMessage, type SpotifyImportStatus } from './api';
import { combineSpotifyExports, maxExportBytes, parseSpotifyExport, type SpotifyImport } from './spotify';
import { $, dialog } from './view';

export class SpotifyImporter {
  private input: SpotifyImport | null = null;
  private current: SpotifyImportStatus | null = null;
  private reading = 0;
  private generation = 0;
  private busy = false;
  constructor(private readonly changed: (playlist?: string) => Promise<void>, private readonly userId: () => string | null) {
    $<HTMLInputElement>('#spotify-files').onchange = () => { void this.read(); };
    $<HTMLFormElement>('#spotify-form').onsubmit = (e) => { e.preventDefault(); void this.start(); };
    $('#spotify-retry').onclick = () => { void this.retry(); };
  }
  open(): void { dialog('spotify-dialog').showModal(); }
  async restore(): Promise<void> {
    const user = this.userId();
    if (!user) return;
    let id: string | null = null;
    try { id = localStorage.getItem(`musica:spotify:${user}`); } catch { /* Storage is optional. */ }
    if (!id || !/^[0-9a-f-]{36}$/i.test(id)) return;
    this.current = { id, tracks: [] };
    try { await this.poll(); } catch (error) { $('#spotify-error').textContent = errorMessage(error); }
  }
  reset(): void {
    this.generation++; this.reading++; this.input = null; this.current = null; this.busy = false;
    $<HTMLFormElement>('#spotify-form').reset(); $('#spotify-summary').textContent = ''; $('#spotify-progress').textContent = '';
    $('#spotify-error').textContent = ''; $<HTMLButtonElement>('#spotify-start').disabled = true; $('#spotify-retry').hidden = true;
    $<HTMLButtonElement>('#spotify-retry').disabled = false;
    $<HTMLInputElement>('#spotify-files').disabled = false;
  }
  private async read(): Promise<void> {
    const version = ++this.reading;
    this.input = null; $('#spotify-error').textContent = ''; $<HTMLButtonElement>('#spotify-start').disabled = true;
    const files = [...($<HTMLInputElement>('#spotify-files').files ?? [])];
    $('#spotify-summary').textContent = 'Читаем файлы…';
    try {
      if (!files.length || files.length > 2) throw new Error('Выберите один или два файла Spotify JSON');
      const parsed = await Promise.all(files.map(async (file) => {
        if (file.size > maxExportBytes) throw new Error(`${file.name}: файл превышает 16 МБ`);
        try { return parseSpotifyExport(JSON.parse((await file.text()).replace(/^\uFEFF/, '')) as unknown); }
        catch (error) { throw new Error(`${file.name}: ${error instanceof SyntaxError ? 'некорректный JSON' : errorMessage(error)}`); }
      }));
      if (version !== this.reading) return;
      const combined = combineSpotifyExports(parsed); this.input = combined.input;
      $('#spotify-summary').textContent = `${combined.tracks} уникальных треков · ${combined.input.playlists.length} плейлистов${combined.skipped ? ` · пропущено подкастов и локальных файлов: ${combined.skipped}` : ''}`;
      $<HTMLButtonElement>('#spotify-start').disabled = false;
    } catch (error) {
      if (version !== this.reading) return;
      $('#spotify-summary').textContent = ''; $('#spotify-error').textContent = errorMessage(error);
    }
  }
  private async start(): Promise<void> {
    if (!this.input || this.busy) return;
    const generation = this.generation;
    this.busy = true; this.current = null; $<HTMLButtonElement>('#spotify-start').disabled = true;
    $<HTMLInputElement>('#spotify-files').disabled = true; $('#spotify-error').textContent = ''; $('#spotify-retry').hidden = true;
    try {
      const result = await api.importSpotify(this.input);
      if (generation !== this.generation) return;
      this.input = null;
      this.current = { id: result.id, tracks: [] };
      const user = this.userId();
      try { if (user) localStorage.setItem(`musica:spotify:${user}`, result.id); } catch { /* Import works without browser storage. */ }
      $('#spotify-progress').textContent = `${result.tracks} треков поставлены в очередь. Можно закрыть это окно.`;
      await this.changed(result.playlists[0]);
      await this.poll();
    } catch (error) { if (generation === this.generation) $('#spotify-error').textContent = errorMessage(error); }
    finally {
      if (generation === this.generation) {
        this.busy = false; $<HTMLInputElement>('#spotify-files').disabled = false;
        $<HTMLButtonElement>('#spotify-start').disabled = !this.input;
      }
    }
  }
  async poll(): Promise<void> {
    const id = this.current?.id; const generation = this.generation;
    if (!id) return;
    let result: SpotifyImportStatus;
    try { result = await api.spotifyImportStatus(id); }
    catch (error) {
      if (error instanceof ApiError && error.status === 404 && generation === this.generation) {
        this.current = null; $('#spotify-progress').textContent = 'Треки этого импорта удалены'; $('#spotify-retry').hidden = true;
        return;
      }
      throw error;
    }
    if (generation !== this.generation || this.current?.id !== id) return;
    this.current = result;
    const count = (predicate: (t: SpotifyImportStatus['tracks'][number]) => boolean) => result.tracks.filter(predicate).length;
    const failed = count((t) => t.download === 'failed' || t.preparation === 'failed');
    $('#spotify-progress').textContent = `Готово: ${count((t) => t.status === 'streamed')} из ${result.tracks.length} · скачивание: ${count((t) => t.download === 'processing')} · в очереди: ${count((t) => t.download === 'queued')} · подготовка: ${count((t) => t.status === 'ready' && t.preparation !== 'failed')}${failed ? ` · ошибки: ${failed}` : ''}`;
    $('#spotify-retry').hidden = !failed;
  }
  private async retry(): Promise<void> {
    if (!this.current || this.busy) return;
    this.busy = true; const generation = this.generation; const id = this.current.id;
    const button = $<HTMLButtonElement>('#spotify-retry'); button.disabled = true;
    try {
      await api.retrySpotifyImport(id);
      if (generation !== this.generation) return;
      for (const track of this.current?.tracks ?? []) if (track.download === 'completed' && track.preparation === 'failed') await api.prepare(track.id);
      await this.poll(); $('#spotify-error').textContent = '';
    } catch (error) { if (generation === this.generation) $('#spotify-error').textContent = errorMessage(error); }
    finally { if (generation === this.generation) { this.busy = false; button.disabled = false; } }
  }
}
