import { storageApi } from './api';
import type { Storage } from './model';

/** Владеет статистикой страницы и отменой запросов при смене страницы. */
export class StorageState {
  value = $state<Storage | null>(null);
  loading = $state(false);
  busy = $state(false);
  error = $state('');
  result = $state<{ removed: number; skipped: number } | null>(null);
  private controller: AbortController | null = null;
  private disposed = false;

  /** Загружает свежий снимок; устаревшие ответы не меняют страницу. */
  async refresh(failure: (error: unknown) => string): Promise<void> {
    this.controller?.abort();
    const controller = new AbortController();
    this.controller = controller;
    this.loading = true;
    this.error = '';

    try {
      const value = await storageApi.read(
        AbortSignal.any([controller.signal, AbortSignal.timeout(30000)]),
      );
      if (!controller.signal.aborted) this.value = value;
    } catch (error) {
      if (!controller.signal.aborted) this.error = failure(error);
    } finally {
      if (this.controller === controller) this.loading = false;
    }
  }

  /** Выполняет один пакет очистки без автоматических повторов чувствительного POST. */
  async cleanup(failure: (error: unknown) => string): Promise<void> {
    if (this.busy || this.disposed) return;
    this.busy = true;
    this.error = '';
    try {
      this.result = await storageApi.cleanup();
      if (!this.disposed) await this.refresh(failure);
    } catch (error) {
      if (!this.disposed) this.error = failure(error);
    } finally {
      this.busy = false;
    }
  }

  /** Отменяет чтение при уничтожении страницы; отправленный POST не отменяет серверную очистку. */
  dispose(): void {
    this.disposed = true;
    this.controller?.abort();
  }
}
