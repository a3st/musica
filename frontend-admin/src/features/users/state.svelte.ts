import { usersApi } from './api';
import type { RegisteredUser } from './model';

/** Владеет списком аккаунтов и отменяет устаревшие чтения. */
export class UsersState {
  items = $state<RegisteredUser[]>([]);
  loading = $state(false);
  busy = $state(false);
  error = $state('');
  private controller: AbortController | null = null;
  private disposed = false;

  /** Обновляет список; ответы старого запроса игнорируются после смены страницы. */
  async refresh(failure: (error: unknown) => string): Promise<void> {
    this.controller?.abort();
    const controller = new AbortController();
    this.controller = controller;
    this.loading = true;
    this.error = '';
    try {
      const users = await usersApi.list(
        AbortSignal.any([controller.signal, AbortSignal.timeout(30000)]),
      );
      if (!controller.signal.aborted) this.items = users;
    } catch (error) {
      if (!controller.signal.aborted) this.error = failure(error);
    } finally {
      if (this.controller === controller) this.loading = false;
    }
  }

  /** Выполняет одну подтверждённую мутацию и перечитывает список без автоматического повтора. */
  async mutate(
    operation: () => Promise<void>,
    failure: (error: unknown) => string,
  ): Promise<boolean> {
    if (this.busy || this.disposed) return false;
    this.busy = true;
    this.error = '';
    try {
      await operation();
      if (!this.disposed) await this.refresh(failure);
      return true;
    } catch (error) {
      if (!this.disposed) this.error = failure(error);
      return false;
    } finally {
      this.busy = false;
    }
  }

  /** Отменяет чтение при уничтожении страницы. */
  dispose(): void {
    this.disposed = true;
    this.controller?.abort();
  }
}
