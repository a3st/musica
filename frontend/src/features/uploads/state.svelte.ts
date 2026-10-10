import { t } from '../../shared/i18n';
import { errorMessage } from '../../shared/api/errors';
import { tracksApi } from '../tracks/api';
import { uploadFile } from './api';
import type { UploadItem } from './model';

export class UploadsState {
  busy = $state(false);
  queue = $state<UploadItem[]>([]);
  open = $state(false);
  private key = 0;
  private generation = 0;
  constructor(
    private readonly changed: () => Promise<void>,
    private readonly notify: (message: string) => void,
  ) {}
  get count(): number {
    return this.queue.filter((item) => ['waiting', 'uploading', 'preparing'].includes(item.state))
      .length;
  }
  get canStart(): boolean {
    return !this.busy && this.queue.some((item) => item.state === 'waiting');
  }
  reset(): void {
    this.generation++;
    for (const item of this.queue) item.controller?.abort();
    this.queue = [];
    this.busy = false;
    this.open = false;
  }
  add(files: FileList | File[]): void {
    for (const file of Array.from(files)) {
      if (this.queue.length >= 50) {
        this.notify(t('uploads.queueFull'));
        break;
      }
      if (
        !/\.(mp3|flac|wav|ogg|aac|m4a|webm)$/i.test(file.name) &&
        !file.type.startsWith('audio/')
      ) {
        this.notify(t('uploads.notAudio', { filename: file.name }));
        continue;
      }
      if (!file.size || file.size > 64 * 1024 * 1024) {
        this.notify(t('uploads.invalidSize', { filename: file.name }));
        continue;
      }
      const stem = file.name.replace(/\.[^.]+$/, '');
      const parts = stem.split(' - ');
      this.queue.push({
        key: ++this.key,
        file,
        title: Array.from(parts.length > 1 ? parts.slice(1).join(' - ') : stem)
          .slice(0, 256)
          .join(''),
        artist: Array.from(parts.length > 1 ? parts[0] : t('uploads.unknownArtist'))
          .slice(0, 256)
          .join(''),
        state: 'waiting',
        progress: 0,
      });
    }
  }
  remove(item: UploadItem): void {
    if (item.state === 'uploading') item.controller?.abort();
    else this.queue = this.queue.filter((value) => value.key !== item.key);
  }
  retry(item: UploadItem): void {
    item.state = 'waiting';
    item.error = undefined;
  }
  async start(): Promise<void> {
    if (this.busy) return;
    if (
      this.queue.some(
        (item) => item.state === 'waiting' && (!item.title.trim() || !item.artist.trim()),
      )
    ) {
      this.notify(t('uploads.metadataRequired'));
      return;
    }
    const generation = this.generation;
    this.busy = true;
    try {
      for (const item of this.queue) {
        if (generation !== this.generation) return;
        if (item.state !== 'waiting') continue;
        item.state = 'uploading';
        item.controller = new AbortController();
        try {
          if (!item.id)
            item.id = await tracksApi.createTrack(item.title.trim(), item.artist.trim(), []);
          if (item.controller.signal.aborted)
            throw new DOMException(t('common.cancelled'), 'AbortError');
          if (!item.uploaded) {
            const existing = await tracksApi.preparation(item.id);
            if (existing.status !== 'pending') item.uploaded = true;
            else {
              await uploadFile(
                item.id,
                item.file,
                (percent) => {
                  item.progress = percent;
                },
                item.controller.signal,
              );
              item.uploaded = true;
            }
          }
          const state = await tracksApi.prepare(item.id);
          item.state = state.status === 'streamed' ? 'done' : 'preparing';
        } catch (error) {
          if (error instanceof DOMException && error.name === 'AbortError') {
            item.state = 'cancelled';
            if (item.id && !item.uploaded) {
              try {
                await tracksApi.removeTrack(item.id);
              } catch {
                this.notify(t('uploads.cancelledHint'));
              }
            }
          } else {
            item.state = 'error';
            item.error = errorMessage(error);
          }
        }
      }
      if (generation === this.generation) await this.changed();
    } catch (error) {
      if (generation === this.generation) this.notify(errorMessage(error));
    } finally {
      if (generation === this.generation) this.busy = false;
    }
  }
  async poll(): Promise<void> {
    const generation = this.generation;
    for (const item of this.queue.filter((item) => item.state === 'preparing').slice(0, 10)) {
      const state = await tracksApi.preparation(item.id!);
      if (generation !== this.generation) return;
      if (state.status === 'streamed') item.state = 'done';
      else if (state.preparation === 'failed') {
        item.state = 'error';
        item.error = t('uploads.preparationFailed');
      }
    }
  }
}
