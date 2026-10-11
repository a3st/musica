import { createTranslator, type Locale } from './index';
import { readPreference, writePreference } from '../utils/storage';

/** Хранит язык админки независимо от настроек плеера. */
export class LanguageState {
  locale = $state<Locale>(readPreference('musica-admin:locale') === 'en-US' ? 'en-US' : 'ru-RU');
  readonly t = createTranslator(() => this.locale);

  /** Применяет поддерживаемый язык и сохраняет выбор для следующего запуска. */
  set(value: string): void {
    if (value !== 'ru-RU' && value !== 'en-US') return;

    this.locale = value;
    writePreference('musica-admin:locale', value);
  }
}
