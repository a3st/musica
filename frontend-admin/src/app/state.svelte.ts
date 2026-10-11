import { LanguageState } from '../shared/i18n/state.svelte';
import { authApi } from '../features/auth/api';
import type { User } from '../features/auth/model';
import { ApiError } from '../shared/api/client';

/** Владеет состояниями оболочки админки на время жизни приложения. */
export class Application {
  readonly language = new LanguageState();
  user = $state<User | null>(null);
  loading = $state(true);
  error = $state('');
  notice = $state('');
  page = $state<'profile' | 'storage' | 'users'>('profile');

  /** Проверяет сессию; обычный 401 не показывается как ошибка за формой входа. */
  async initialize(signal: AbortSignal): Promise<void> {
    try {
      this.user = await authApi.me(signal);
    } catch (error) {
      if (!signal.aborted && !(error instanceof ApiError && error.status === 401))
        this.error = this.failure(error);
    } finally {
      if (!signal.aborted) this.loading = false;
    }
  }

  /** Входит и получает профиль до открытия защищённого интерфейса. */
  async login(username: string, password: string): Promise<void> {
    await authApi.login(username, password);
    this.user = await authApi.me();
    this.error = '';
    this.notice = '';
    this.page = 'profile';
  }

  /** Завершает сессию; сетевой сбой оставляет профиль видимым и показывает ошибку. */
  async logout(): Promise<void> {
    try {
      await authApi.logout();
      this.signedOut();
    } catch (error) {
      if (error instanceof ApiError && error.status === 401) this.signedOut();
      else this.error = this.failure(error);
    }
  }

  /** Очищает защищённое состояние после выхода или удаления аккаунта. */
  signedOut(): void {
    this.user = null;
    this.page = 'profile';
    this.error = '';
  }

  /** Переводит ошибки без раскрытия технических подробностей пользователю. */
  failure(error: unknown): string {
    if (error instanceof ApiError) {
      if (error.status === 401) return this.language.t('errors.credentials');
      if (error.status === 403) return this.language.t('errors.forbidden');
      if (error.status === 409) return this.language.t('errors.busy');
      if (error.status === 400) return this.language.t('errors.input');
    }
    return this.language.t('errors.request');
  }
}
