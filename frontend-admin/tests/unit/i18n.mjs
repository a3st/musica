import assert from 'node:assert/strict';
import { moduleUrl } from '../helpers/typescript.mjs';

const load = (path) => import(moduleUrl(new URL(`../../src/shared/i18n/${path}`, import.meta.url)));
const { russian } = await load('locales/ru-RU.ts');
const { english } = await load('locales/en-US.ts');
const { translate, createTranslator } = await load('index.ts');
const placeholders = (text) =>
  [...new Set([...text.matchAll(/\{([^{}]+)\}/g)].map((match) => match[1]))].sort();

assert.deepEqual(Object.keys(english).sort(), Object.keys(russian).sort());

for (const key of Object.keys(russian)) {
  assert.ok(russian[key].trim() && english[key].trim(), `Nonempty translation: ${key}`);
  assert.deepEqual(placeholders(english[key]), placeholders(russian[key]), `Parameters: ${key}`);
}

assert.equal(translate('admin.heading', 'ru-RU'), 'Панель управления');
assert.equal(translate('admin.heading', 'en-US'), 'Administration');

let locale = 'ru-RU';
const t = createTranslator(() => locale);
assert.equal(t('profile.language'), 'Язык');
locale = 'en-US';
assert.equal(t('profile.language'), 'Language');
assert.equal(t('storage.cleanupResult', { removed: 2, skipped: 1 }), 'Removed: 2. Skipped: 1.');

console.log('PASS: admin locales, matching keys and parameters, Unicode and language switching.');
