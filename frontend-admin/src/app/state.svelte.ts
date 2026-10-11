import { LanguageState } from '../shared/i18n/state.svelte';
import { authApi } from '../features/auth/api';
import type { User } from '../features/auth/model';
import { ApiError } from '../shared/api/client';
import { playerUrl } from '../shared/navigation/player';
import { validateReturnUrl } from '../shared/navigation/return';
import { readRegistration } from '../features/capabilities/api';
import { readPage, writePage, type Page } from './navigation';

/** Владеет состояниями оболочки админки на время жизни приложения. */
export class Application {
  readonly language = new LanguageState();
  user = $state<User | null>(null);
  loading = $state(true);
  registrationEnabled = $state(false);
  error = $state('');
  notice = $state('');
  page = $state<Page>(readPage());

  /** Открывает доступный раздел и сохраняет его в истории браузера. */
  selectPage(page: Page): void {
    if (page !== 'profile' && this.user?.role !== 'admin') return;
    if (page === this.page) return;

    this.page = page;
    writePage(page);
  }

  /** Восстанавливает раздел при переходе назад или вперёд, проверяя роль. */
  restorePage(): void {
    const page = readPage();
    this.page = this.user?.role === 'admin' ? page : 'profile';
  }

  /** Возвращает в плеер после авторизации, сохраняя открытый плейлист. */
  private returnToPlayer(): void {
    const destination = validateReturnUrl(
      new URL(window.location.href).searchParams.get('return_to'),
      new URL(playerUrl(), window.location.origin).href,
    );
    if (destination) window.location.replace(destination);
  }

  /** Проверяет сессию; обычный 401 не показывается как ошибка за формой входа. */
  async initialize(signal: AbortSignal): Promise<void> {
    const registration = readRegistration(signal)
      .then((enabled) => {
        if (!signal.aborted) this.registrationEnabled = enabled;
      })
      .catch(() => {});
    try {
      this.user = await authApi.me(signal);
      if (!signal.aborted) this.restorePage();
      if (!signal.aborted) this.returnToPlayer();
    } catch (error) {
      if (!signal.aborted && !(error instanceof ApiError && error.status === 401))
        this.error = this.failure(error);
    } finally {
      await registration;
      if (!signal.aborted) this.loading = false;
    }
  }

  /** Выполняет вход или регистрацию и получает профиль до открытия защищённого интерфейса. */
  async signIn(username: string, password: string, register: boolean): Promise<void> {
    await authApi.signIn(username, password, register);
    this.user = await authApi.me();
    this.error = '';
    this.notice = '';
    this.restorePage();
    this.returnToPlayer();
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
