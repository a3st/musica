import { english } from './locales/en-US';

export type Locale = 'ru-RU' | 'en-US';
export let locale: Locale = 'ru-RU';
try { if (localStorage.getItem('musica:locale') === 'en-US') locale = 'en-US'; } catch { /* Optional storage. */ }
if (typeof document !== 'undefined') document.documentElement.lang = locale;
export function t(message: string): string { return locale === 'en-US' ? english[message] ?? message : message; }

// Translate the template before inserting values: names and other user data stay intact.
export function msg(parts: TemplateStringsArray, ...values: unknown[]): string {
  const key = parts.map((part, index) => part + (index < values.length ? `{${index}}` : '')).join('');
  return t(key).replace(/\{(\d+)\}/g, (_, index: string) => String(values[Number(index)]));
}
const keys = Object.keys(english).filter((key) => !key.includes('{')).sort((a, b) => b.length - a.length);
const pattern = new RegExp(keys.map((key) => key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|'), 'g');
export function markup(literal: string): string {
  return locale === 'en-US' ? literal.replace(pattern, (key) => english[key]) : literal;
}
export function html(parts: TemplateStringsArray, ...values: unknown[]): string {
  return parts.map((part, index) => markup(part) + (index < values.length ? String(values[index]) : '')).join('');
}
const bindings: (() => void)[] = [];
const reverse = Object.fromEntries(Object.entries(english).filter(([key]) => !key.includes('{')).map(([key, translation]) => [translation, key]));
const reversePattern = new RegExp(Object.keys(reverse).sort((a, b) => b.length - a.length).map((key) => key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|'), 'g');
// Capture only the shell, before API data is inserted. User metadata is never translated.
export function initLocale(): void {
  const source = (value: string): string => {
    if (locale === 'ru-RU') return value;
    return value.replace(reversePattern, (key) => reverse[key]);
  };
  const walker = document.createTreeWalker(document.querySelector('#app')!, NodeFilter.SHOW_TEXT);
  while (walker.nextNode()) {
    const node = walker.currentNode;
    const original = source(node.nodeValue ?? '');
    if (markupForEnglish(original) === original) continue;
    let last = node.nodeValue;
    bindings.push(() => {
      if (!node.isConnected || node.nodeValue !== last) return;
      node.nodeValue = markup(original); last = node.nodeValue;
    });
  }
  document.querySelectorAll('#app *').forEach((node) => {
    for (const attr of ['aria-label', 'title', 'placeholder']) {
      const value = node.getAttribute(attr); if (!value) continue;
      const original = source(value); if (markupForEnglish(original) === original) continue;
      let last = value;
      bindings.push(() => {
        if (!node.isConnected || node.getAttribute(attr) !== last) return;
        last = markup(original); node.setAttribute(attr, last);
      });
    }
  });
}
function markupForEnglish(value: string): string { return value.replace(pattern, (key) => english[key]); }
export function setLocale(value: string): void {
  if (value !== 'ru-RU' && value !== 'en-US') return;
  locale = value;
  try { localStorage.setItem('musica:locale', value); } catch { /* Works for the current session. */ }
  document.documentElement.lang = locale;
  bindings.forEach((apply) => apply());
  window.dispatchEvent(new Event('localechange'));
}
