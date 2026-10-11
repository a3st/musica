import { createTranslator, type Locale } from './index';
import { readPreference, writePreference } from '../utils/storage';
import { readLanguage, writeLanguage } from './preference';

/** Синхронизирует язык профиля с плеером на одном хосте. */
export class LanguageState {
  locale = $state<Locale>(
    readLanguage() ??
      (readPreference('musica:locale') === 'en-US' ||
      readPreference('musica-admin:locale') === 'en-US'
        ? 'en-US'
        : 'ru-RU'),
  );
  readonly t = createTranslator(() => this.locale);

  constructor() {
    writeLanguage(this.locale);
  }

  /** Применяет поддерживаемый язык и сохраняет выбор для следующего запуска. */
  set(value: string): void {
    if (value !== 'ru-RU' && value !== 'en-US') return;

    this.locale = value;
    writeLanguage(value);
    writePreference('musica:locale', value);
  }

  /** Подхватывает язык другого окна при возврате фокуса или событии storage. */
  sync(): void {
    const value = readLanguage();
    if (value) this.locale = value;
  }
}
