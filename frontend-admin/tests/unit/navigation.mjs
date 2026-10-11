import assert from 'node:assert/strict';
import { moduleUrl } from '../helpers/typescript.mjs';

const { validateReturnUrl } = await import(moduleUrl(new URL('../../src/shared/navigation/return.ts', import.meta.url)));
const player = 'https://music.example.com/';

assert.equal(validateReturnUrl('/?playlist=123#track', player), `${player}?playlist=123#track`);
assert.equal(validateReturnUrl('http://localhost:5173/?playlist=123', 'http://localhost:5173/'), 'http://localhost:5173/?playlist=123');
for (const candidate of [null, '', 'https://evil.example/', '//evil.example/', 'javascript:alert(1)',
  'https://user:password@music.example.com/', 'http://music.example.com/',
  'https://music.example.com:444/', '/profile/', '/profile?return_to=/']) {
  assert.equal(validateReturnUrl(candidate, player), null, String(candidate));
}
assert.equal(validateReturnUrl('/music/playlist', `${player}music/`), `${player}music/playlist`);
assert.equal(validateReturnUrl('/music-other/', `${player}music/`), null);
assert.equal(validateReturnUrl('/music/../profile/', `${player}music/`), null);
console.log('PASS: player return preserves navigation and rejects open redirects.');
