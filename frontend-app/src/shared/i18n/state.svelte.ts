import { createTranslator, setTranslationLocale, type Locale } from './index';
import { readPreference, writePreference } from '../utils/storage';

export class LanguageState {
  locale = $state<Locale>(readPreference('musica:locale') === 'en-US' ? 'en-US' : 'ru-RU');
  t = createTranslator(() => this.locale);

  /** Восстанавливает язык и синхронизирует переводы вне компонентов. */
  constructor() {
    setTranslationLocale(this.locale);
  }

  /** Применяет поддерживаемый язык и сохраняет выбор для следующего запуска. */
  set(value: string): void {
    if (value !== 'ru-RU' && value !== 'en-US') return;

    this.locale = value;
    setTranslationLocale(value);
    writePreference('musica:locale', value);
  }
}
