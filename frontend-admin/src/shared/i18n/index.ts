import { english } from './locales/en-US';
import { russian } from './locales/ru-RU';
import type { Locale, MessageKey, TranslationArgs } from './types';

export type { Locale, MessageKey, Messages, TranslationArgs } from './types';

/** Подставляет именованные параметры в сообщение выбранного языка. */
export function translate<Key extends MessageKey>(
  key: Key,
  locale: Locale,
  ...args: TranslationArgs<Key>
): string {
  const message = (locale === 'en-US' ? english : russian)[key];
  const params = args[0] as Record<string, string | number> | undefined;

  return message.replace(/\{([^{}]+)\}/g, (_, name: string) =>
    String(params?.[name] ?? `{${name}}`),
  );
}

/** Создаёт переводчик, читающий актуальный язык при каждом вызове. */
export function createTranslator(locale: () => Locale) {
  return <Key extends MessageKey>(key: Key, ...args: TranslationArgs<Key>): string =>
    translate(key, locale(), ...args);
}
