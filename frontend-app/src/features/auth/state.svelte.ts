import { authApi } from './api';
import type { User } from './model';

export class AuthState {
  user = $state<User | null>(null);
  private version = 0;

  /** Загружает пользователя, игнорируя ответы после сброса или нового запроса. */
  async load(): Promise<void> {
    const version = ++this.version;
    const user = await authApi.me();
    if (version === this.version) this.user = user;
  }

  /** Очищает пользователя и инвалидирует прежние запросы сессии. */
  reset(): void {
    this.version++;
    this.user = null;
  }
}
