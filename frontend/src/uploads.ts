import { api, errorMessage, uploadFile, type PlaylistSummary } from './api';
import { escape, icon } from './icons';
import { $, dialog } from './view';

type State = 'waiting' | 'uploading' | 'preparing' | 'done' | 'error' | 'cancelled';
interface Item { key: number; file: File; title: string; artist: string; target: string; state: State; progress: number; id?: string; uploaded?: boolean; error?: string; controller?: AbortController }
export class Uploads {
  busy = false;
  private readonly queue: Item[] = [];
  private key = 0;
  constructor(private readonly context: () => { playlists: PlaylistSummary[]; selected: string | null; defaultId: string | null }, private readonly changed: () => Promise<void>, private readonly notify: (message: string) => void) {
    $<HTMLInputElement>('#file-input').onchange = (e) => { const input = e.target as HTMLInputElement; if (input.files) this.add(input.files); input.value = ''; };
    $('#drop-zone').onkeydown = (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); $<HTMLInputElement>('#file-input').click(); } };
    for (const name of ['dragenter', 'dragover']) $('#drop-zone').addEventListener(name, (e) => { e.preventDefault(); $('#drop-zone').classList.add('dragging'); });
    $('#drop-zone').addEventListener('dragleave', () => $('#drop-zone').classList.remove('dragging'));
    $('#drop-zone').addEventListener('drop', (e) => { e.preventDefault(); $('#drop-zone').classList.remove('dragging'); if (e.dataTransfer?.files) this.add(e.dataTransfer.files); });
    $('#upload-target').onchange = () => { for (const item of this.queue) if (item.state === 'waiting') item.target = $<HTMLSelectElement>('#upload-target').value; };
    $('#upload-list').addEventListener('input', (e) => {
      const input = e.target as HTMLInputElement; const item = this.queue.find((item) => item.key === Number(input.dataset.uploadTitle ?? input.dataset.uploadArtist));
      if (item) { if (input.dataset.uploadTitle) item.title = input.value; else item.artist = input.value; }
    });
    $('#upload-list').addEventListener('click', (e) => {
      const element = (e.target as Element).closest<HTMLElement>('[data-remove-upload],[data-retry-upload]'); if (!element) return;
      const index = this.queue.findIndex((item) => item.key === Number(element.dataset.removeUpload ?? element.dataset.retryUpload)); if (index < 0) return;
      const item = this.queue[index];
      if (element.dataset.retryUpload) { item.state = 'waiting'; item.error = undefined; this.render(); }
      else if (item.state === 'uploading') item.controller?.abort();
      else { this.queue.splice(index, 1); this.render(); }
    });
    $('#start-upload').onclick = () => { void this.start(); };
  }
  open(): void {
    const { playlists, selected } = this.context();
    $<HTMLSelectElement>('#upload-target').innerHTML = playlists.filter((p) => p.role !== 'viewer').map((p) => `<option value="${p.id}" ${p.id === selected ? 'selected' : ''}>${escape(p.title)}</option>`).join('');
    this.render(); dialog('upload-dialog').showModal();
  }
  reset(): void { for (const item of this.queue) item.controller?.abort(); this.queue.length = 0; this.render(); dialog('upload-dialog').close(); }
  private add(files: FileList): void {
    for (const file of Array.from(files)) {
      if (this.queue.length >= 50) { this.notify('В очереди может быть до 50 файлов. Уберите завершённые загрузки.'); break; }
      if (!/\.(mp3|flac|wav|ogg|aac|m4a|webm)$/i.test(file.name) && !file.type.startsWith('audio/')) { this.notify(`«${file.name}» не похож на аудиофайл`); continue; }
      if (!file.size || file.size > 64 * 1024 * 1024) { this.notify(`«${file.name}»: файл пустой или больше 64 МБ`); continue; }
      const stem = file.name.replace(/\.[^.]+$/, ''); const parts = stem.split(' - ');
      this.queue.push({ key: ++this.key, file, title: Array.from(parts.length > 1 ? parts.slice(1).join(' - ') : stem).slice(0, 256).join(''), artist: Array.from(parts.length > 1 ? parts[0] : 'Неизвестный исполнитель').slice(0, 256).join(''), target: $<HTMLSelectElement>('#upload-target').value, state: 'waiting', progress: 0 });
    }
    this.render();
  }
  private render(): void {
    $('#upload-list').innerHTML = this.queue.map((item) => `<div class="upload-item ${item.state}" data-upload-key="${item.key}"><div class="file-symbol">${icon(item.state === 'done' ? 'check' : 'music')}</div><div class="upload-item-main">${item.state === 'waiting' ? `<div class="upload-fields"><input data-upload-title="${item.key}" aria-label="Название ${escape(item.file.name)}" value="${escape(item.title)}" maxlength="256" required /><input data-upload-artist="${item.key}" aria-label="Исполнитель ${escape(item.file.name)}" value="${escape(item.artist)}" maxlength="256" required /></div>` : `<strong>${escape(item.title)}</strong><span>${escape(item.artist)}</span>`}<small>${item.state === 'error' ? escape(item.error ?? 'Ошибка загрузки') : item.state === 'uploading' ? `Загрузка · ${item.progress}%` : item.state === 'preparing' ? 'Подготовка к прослушиванию…' : item.state === 'done' ? 'Можно слушать' : item.state === 'cancelled' ? 'Загрузка отменена' : `${(item.file.size / 1024 / 1024).toFixed(1)} МБ · ${escape(item.file.name)}`}</small>${item.state === 'uploading' ? `<progress value="${item.progress}" max="100" aria-label="Загрузка ${escape(item.title)}"></progress>` : ''}</div>${item.state === 'error' ? `<button class="icon-button" data-retry-upload="${item.key}" aria-label="Повторить загрузку">${icon('refresh')}</button>` : ''}${item.state !== 'preparing' ? `<button class="icon-button" data-remove-upload="${item.key}" aria-label="${item.state === 'uploading' ? 'Отменить загрузку' : 'Убрать из списка'}">${icon('close')}</button>` : '<span class="spinner" aria-label="Подготовка"></span>'}</div>`).join('');
    $<HTMLButtonElement>('#start-upload').disabled = this.busy || !this.queue.some((item) => item.state === 'waiting');
    const count = this.queue.filter((item) => ['waiting', 'uploading', 'preparing'].includes(item.state)).length;
    $('#upload-count').textContent = String(count); $('#upload-count').hidden = count === 0;
  }
  private async start(): Promise<void> {
    if (this.busy) return;
    if (this.queue.some((item) => item.state === 'waiting' && (!item.title.trim() || !item.artist.trim()))) { this.notify('Укажите название и исполнителя для каждого файла'); return; }
    this.busy = true; this.render();
    try {
      for (const item of this.queue) {
        if (item.state !== 'waiting') continue;
        item.state = 'uploading'; item.controller = new AbortController(); this.render();
        try {
          if (!item.id) item.id = await api.createTrack(item.title.trim(), item.artist.trim(), item.target && item.target !== this.context().defaultId ? [item.target] : []);
          if (item.controller.signal.aborted) throw new DOMException('Отменено', 'AbortError');
          if (!item.uploaded) {
            const existing = await api.preparation(item.id);
            if (existing.status !== 'pending') item.uploaded = true;
            else { await uploadFile(item.id, item.file, (percent) => { item.progress = percent; const row = document.querySelector<HTMLElement>(`[data-upload-key="${item.key}"]`); const progress = row?.querySelector('progress'); if (progress) progress.value = percent; const label = row?.querySelector('small'); if (label) label.textContent = `Загрузка · ${percent}%`; }, item.controller.signal); item.uploaded = true; }
          }
          const state = await api.prepare(item.id); item.state = state.status === 'streamed' ? 'done' : 'preparing';
        } catch (error) {
          if (error instanceof DOMException && error.name === 'AbortError') {
            item.state = 'cancelled';
            if (item.id && !item.uploaded) { try { await api.removeTrack(item.id); } catch { this.notify('Загрузка отменена. Незавершённый трек можно удалить из Uploads.'); } }
          } else { item.state = 'error'; item.error = errorMessage(error); }
        }
        this.render();
      }
      await this.changed();
    } catch (error) { this.notify(errorMessage(error)); }
    finally { this.busy = false; this.render(); }
  }
  async poll(): Promise<void> {
    let changed = false;
    for (const item of this.queue.filter((item) => item.state === 'preparing').slice(0, 10)) {
      const state = await api.preparation(item.id!);
      if (state.status === 'streamed') { item.state = 'done'; changed = true; }
      else if (state.preparation === 'failed') { item.state = 'error'; item.error = 'Файл загружен, но подготовка не удалась. Можно повторить.'; changed = true; }
    }
    if (changed) this.render();
  }
}
