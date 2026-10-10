import assert from 'node:assert/strict';
import { moduleUrl } from '../helpers/typescript.mjs';

const { parseSearchTracks } = await import(moduleUrl(new URL('../../src/features/web-search/model.ts', import.meta.url)));
const song = {
  provider: 'itunes', external_id: '123', title: '<img src=x> (Live Remix)', artist: 'Artist', album: null,
  artwork_url: 'https://example.com/cover.jpg', source_url: 'https://music.apple.com/track',
};
assert.deepEqual(parseSearchTracks({ tracks: [song] })[0], song);
assert.equal('duration_seconds' in parseSearchTracks({ tracks: [{ ...song, duration_seconds: 123 }] })[0], false);
for (const invalid of [
  { tracks: null },
  { tracks: [song, song] },
  { tracks: [{ ...song, external_id: '123&other=value' }] },
  { tracks: [{ ...song, artwork_url: 'javascript:alert(1)' }] },
  { tracks: [{ ...song, artwork_url: 'https://user:pass@example.com/image' }] },
  { tracks: [{ ...song, provider: 'deezer' }] },
  { tracks: [{ ...song, provider: undefined }] },
  { tracks: [{ ...song, source_url: 'javascript:alert(1)' }] },
]) assert.throws(() => parseSearchTracks(invalid));

const { webSearchApi } = await import(moduleUrl(new URL('../../src/features/web-search/api.ts', import.meta.url)));
const calls = [];
globalThis.fetch = async (url, options) => {
  calls.push({ url, options });
  return new Response(JSON.stringify(options.method === 'POST'
    ? { id: '00000000-0000-4000-8000-000000000001' }
    : { tracks: [song] }), { status: 200 });
};
const controller = new AbortController();
await webSearchApi.search('Artist & Song (Live)', controller.signal);
assert.equal(calls[0].url, '/api/web/search?q=Artist%20%26%20Song%20(Live)');
assert.equal(calls[0].options.credentials, 'same-origin');
assert.equal(calls[0].options.cache, 'no-store');
await webSearchApi.add(song, controller.signal);
assert.deepEqual(JSON.parse(calls[1].options.body), { provider: 'itunes', external_id: '123' });
assert.equal(calls[1].options.method, 'POST');
controller.abort();
assert.equal(calls[0].options.signal.aborted, true);
assert.equal(calls[1].options.signal.aborted, true);
console.log('PASS: catalog validation, recording names, unsafe URLs, query encoding, cookie sessions, provider/ID selection and cancellation.');
