import type { russian } from './locales/ru-RU';

export type Locale = 'ru-RU' | 'en-US';

export type MessageKey = keyof typeof russian;

export type Messages = { readonly [Key in MessageKey]: string };

type Placeholder<Text extends string> = Text extends `${string}{${infer Name}}${infer Rest}`
  ? Name | Placeholder<Rest>
  : never;

export type TranslationArgs<Key extends MessageKey> = [Placeholder<(typeof russian)[Key]>] extends [
  never,
]
  ? []
  : [params: Record<Placeholder<(typeof russian)[Key]>, string | number>];
