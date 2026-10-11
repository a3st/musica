import { createTranslator, setTranslationLocale, type Locale } from './index';
import { readPreference, writePreference } from '../utils/storage';
import { readLanguage, writeLanguage } from './preference';

export class LanguageState {
  locale = $state<Locale>(
    readLanguage() ?? (readPreference('musica:locale') === 'en-US' ? 'en-US' : 'ru-RU'),
  );
  t = createTranslator(() => this.locale);

  /** Восстанавливает язык и синхронизирует переводы вне компонентов. */
  constructor() {
    setTranslationLocale(this.locale);
    writeLanguage(this.locale);
  }

  /** Применяет поддерживаемый язык и сохраняет выбор для следующего запуска. */
  set(value: string): void {
    if (value !== 'ru-RU' && value !== 'en-US') return;

    this.locale = value;
    setTranslationLocale(value);
    writeLanguage(value);
    writePreference('musica:locale', value);
  }

  /** Применяет язык другого окна без повторной записи и событий синхронизации. */
  sync(): void {
    const value = readLanguage();
    if (!value || value === this.locale) return;

    this.locale = value;
    setTranslationLocale(value);
  }
}
