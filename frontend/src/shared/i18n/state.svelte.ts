import { createTranslator, setTranslationLocale, type Locale } from './index';
import { readPreference, writePreference } from '../utils/storage';

export class LanguageState {
  locale = $state<Locale>(readPreference('musica:locale') === 'en-US' ? 'en-US' : 'ru-RU');
  constructor() {
    setTranslationLocale(this.locale);
  }
  t = createTranslator(() => this.locale);
  set(value: string): void {
    if (value !== 'ru-RU' && value !== 'en-US') return;
    this.locale = value;
    setTranslationLocale(value);
    writePreference('musica:locale', value);
  }
}
