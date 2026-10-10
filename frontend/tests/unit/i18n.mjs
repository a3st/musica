import assert from 'node:assert/strict';
import { moduleUrl } from '../helpers/typescript.mjs';

const load = (path) => import(moduleUrl(new URL(`../../src/shared/i18n/${path}`, import.meta.url)));
const { russian } = await load('locales/ru-RU.ts');
const { english } = await load('locales/en-US.ts');
const { t, translate, createTranslator, setTranslationLocale } = await load('index.ts');
const placeholders = (text) => [...new Set([...text.matchAll(/\{([^{}]+)\}/g)].map(match => match[1]))].sort();

assert.deepEqual(Object.keys(english).sort(), Object.keys(russian).sort());
for (const key of Object.keys(russian)) {
  assert.ok(/^[a-z]+\.[a-zA-Z]+$/.test(key), `semantic key: ${key}`);
  assert.ok(russian[key].trim() && english[key].trim(), `nonempty translation: ${key}`);
  assert.deepEqual(placeholders(english[key]), placeholders(russian[key]), `matching parameters: ${key}`);
}
assert.equal(translate('uploads.title', 'ru-RU'), 'Загрузить треки');
assert.equal(translate('uploads.title', 'en-US'), 'Upload Tracks');
assert.equal(translate('playlists.trackCount', 'ru-RU', { count: 0 }), '0 треков');
const { playlistDuration } = await import(moduleUrl(new URL('../../src/features/playlists/duration.ts', import.meta.url)));
const language = locale => ({ t: createTranslator(() => locale) });
assert.equal(playlistDuration({ duration_seconds: 0, duration_complete: true }, language('en-US')), '0 sec');
assert.equal(playlistDuration({ duration_seconds: 3725, duration_complete: true }, language('ru-RU')), '1 ч 2 мин');
assert.equal(playlistDuration({ duration_seconds: 125, duration_complete: false }, language('en-US')), 'at least 2 min 5 sec');
assert.equal(playlistDuration({ duration_seconds: null, duration_complete: false }, language('ru-RU')), 'длительность неизвестна');
assert.equal(translate('player.elapsedOfTotal', 'en-US', { elapsed: '1:05', total: '3:42' }), '1:05 of 3:42');
const title = '<img src=x onerror=alert(1)> {count} $&';
assert.equal(translate('tracks.play', 'en-US', { title }), `Play ${title}`, 'metadata is inserted literally without recursive translation');
assert.equal(translate('spotify.preview', 'en-US', { tracks: 2, playlists: 1, skipped: '' }), '2 unique tracks · 1 playlists');

let locale = 'ru-RU';
const local = createTranslator(() => locale);
assert.equal(local('player.pause'), 'Пауза');
locale = 'en-US';
assert.equal(local('player.pause'), 'Pause');
setTranslationLocale('en-US');
assert.equal(t('errors.connection'), 'Unable to connect to the server');
setTranslationLocale('ru-RU');
assert.equal(t('errors.connection'), 'Не удаётся подключиться к серверу');
console.log('PASS: both locales, matching placeholders, named interpolation, literal metadata and locale switching.');
