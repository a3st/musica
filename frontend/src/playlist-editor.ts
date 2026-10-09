import { api, errorMessage, type Playlist } from './api';
import { t } from './i18n';
import { $, dialog } from './view';

export class PlaylistEditor {
  private id: string | null = null;
  private tags: string[] = [];
  private image: File | null = null;
  private previewUrl: string | null = null;
  private existingImage: string | null = null;
  private busy = false;
  private opening = 0;
  private readonly form = $<HTMLFormElement>('#playlist-form');
  constructor(private readonly saved: (id: string) => Promise<void>, private readonly notify: (message: string) => void) {
    $<HTMLInputElement>('#playlist-image-input').onchange = (event) => { const input = event.target as HTMLInputElement; if (input.files?.[0]) this.chooseImage(input.files[0]); input.value = ''; };
    const drop = $('#playlist-image-drop');
    drop.onkeydown = (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); $<HTMLInputElement>('#playlist-image-input').click(); } };
    for (const type of ['dragenter', 'dragover']) drop.addEventListener(type, (event) => { event.preventDefault(); drop.classList.add('dragging'); });
    drop.addEventListener('dragleave', () => drop.classList.remove('dragging'));
    drop.addEventListener('drop', (event) => { event.preventDefault(); drop.classList.remove('dragging'); if (event.dataTransfer?.files[0]) this.chooseImage(event.dataTransfer.files[0]); });
    $('#playlist-image-clear').onclick = () => { this.image = null; this.preview(); };
    dialog('playlist-dialog').addEventListener('close', () => { this.image = null; this.releasePreview(); });
    this.form.onsubmit = (event) => { event.preventDefault(); void this.save(); };
    window.addEventListener('localechange', () => this.labels());
  }
  async open(id?: string): Promise<void> {
    if (this.busy) return;
    const version = ++this.opening;
    const playlist = id ? await api.playlist(id) : null;
    if (version !== this.opening) return;
    if (playlist?.is_default) { this.notify(t('Настройки Uploads нельзя изменять')); return; }
    this.id = playlist?.id ?? null; this.tags = playlist?.tags ?? []; this.image = null;
    this.existingImage = playlist?.image_key ? `/api/playlists/${playlist.id}/image` : null;
    this.form.reset(); this.form.querySelector<HTMLElement>('.form-error')!.textContent = '';
    $<HTMLInputElement>('#playlist-form [name=title]').value = playlist?.title ?? '';
    $<HTMLTextAreaElement>('#playlist-form [name=description]').value = playlist?.description ?? '';
    $<HTMLSelectElement>('#playlist-form [name=visibility]').value = playlist?.visibility ?? 'private';
    this.labels(); this.preview(); dialog('library-dialog').close(); dialog('playlist-dialog').showModal();
  }
  private labels(): void { $('#playlist-editor-title').textContent = this.id ? t('Редактировать плейлист') : t('Новый плейлист'); $('#playlist-save').textContent = this.id ? t('Сохранить') : t('Создать плейлист'); }
  private chooseImage(file: File): void {
    if (this.busy) return;
    if (!file.size || file.size > 5 * 1024 * 1024 || (file.type ? !['image/png', 'image/jpeg', 'image/webp'].includes(file.type) : !/\.(png|jpe?g|webp)$/i.test(file.name))) {
      this.form.querySelector<HTMLElement>('.form-error')!.textContent = t('Выберите PNG, JPEG или WebP до 5 МБ'); return;
    }
    this.form.querySelector<HTMLElement>('.form-error')!.textContent = ''; this.image = file; this.preview();
  }
  private releasePreview(): void { if (this.previewUrl) URL.revokeObjectURL(this.previewUrl); this.previewUrl = null; }
  private preview(): void {
    this.releasePreview(); this.previewUrl = this.image ? URL.createObjectURL(this.image) : null;
    const preview = $<HTMLImageElement>('#playlist-image-preview');
    const url = this.previewUrl ?? this.existingImage; preview.hidden = !url;
    if (url) preview.src = url; else preview.removeAttribute('src');
    $('#playlist-image-clear').hidden = !this.image;
  }
  private async save(): Promise<void> {
    if (this.busy) return;
    this.busy = true; const button = $<HTMLButtonElement>('#playlist-save'); button.disabled = true;
    const data = new FormData(this.form); const image = this.image;
    const title = String(data.get('title')).trim(); const description = String(data.get('description')).trim();
    const visibility = data.get('visibility') as Playlist['visibility']; const creating = !this.id;
    this.form.querySelector<HTMLElement>('.form-error')!.textContent = '';
    let metadataSaved = false;
    try {
      if (this.id) await api.updatePlaylist(this.id, title, description, visibility, this.tags);
      else this.id = await api.createPlaylist(title, description, visibility);
      metadataSaved = true;
      if (image) await api.setPlaylistImage(this.id, image);
      await this.saved(this.id); dialog('playlist-dialog').close(); this.notify(creating ? t('Плейлист создан') : t('Плейлист обновлён'));
    } catch (error) {
      this.labels();
      this.form.querySelector<HTMLElement>('.form-error')!.textContent = metadataSaved && image ? t('Плейлист сохранён, но обложка не загружена. Нажмите «Сохранить», чтобы повторить.') + ' ' + errorMessage(error) : errorMessage(error);
      if (metadataSaved && this.id) { try { await this.saved(this.id); } catch { /* Preserve the original failure. */ } }
    } finally { this.busy = false; button.disabled = false; }
  }
}
