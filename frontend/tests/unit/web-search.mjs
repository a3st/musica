import assert from 'node:assert/strict';
import { moduleUrl } from '../helpers/typescript.mjs';

const { capabilities } = await import(moduleUrl(new URL('../../src/features/capabilities/model.ts', import.meta.url)));
assert.deepEqual(capabilities({ web_search: false, spotify_import: true }), { web_search: false, spotify_import: true });
for (const invalid of [null, {}, { web_search: 'false', spotify_import: true }, { web_search: true, spotify_import: 1 }]) {
  assert.throws(() => capabilities(invalid));
}

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
    : { library: [], catalog: [song] }), { status: 200 });
};
const controller = new AbortController();
await webSearchApi.search('Artist & Song (Live)', controller.signal);
assert.equal(calls[0].url, '/api/web/search?q=Artist%20%26%20Song%20(Live)');
assert.equal(calls[0].options.credentials, 'same-origin');
assert.equal(calls[0].options.cache, 'no-store');
await webSearchApi.add(song, controller.signal);
assert.deepEqual(JSON.parse(calls[1].options.body), { provider: 'itunes', external_id: '123', add_to_library: true });
await webSearchApi.add(song, controller.signal, false);
assert.equal(JSON.parse(calls[2].options.body).add_to_library, false);
assert.equal(calls[1].options.method, 'POST');
controller.abort();
assert.equal(calls[0].options.signal.aborted, true);
assert.equal(calls[1].options.signal.aborted, true);

const playbackTrack = { id: '00000000-0000-4000-8000-000000000001', title: 'Song', artist: 'Artist',
  owner_id: '00000000-0000-4000-8000-000000000002', owner_kind: 'system', status: 'pending' };
const { waitForDownloadedTrack } = await import(moduleUrl(new URL('../../src/features/web-search/playback.ts', import.meta.url)));
globalThis.fetch = async () => new Response(JSON.stringify({ track: playbackTrack, download: 'failed' }));
await assert.rejects(waitForDownloadedTrack(playbackTrack.id, new AbortController().signal));
globalThis.fetch = async () => new Response(JSON.stringify({ track: { ...playbackTrack, status: 'ready' }, download: 'processing' }));
assert.equal((await waitForDownloadedTrack(playbackTrack.id, new AbortController().signal)).status, 'ready');

const serviceTrack = { ...playbackTrack, status: 'streamed', duration_seconds: 13, artwork_key: 'artwork/cover' };
globalThis.fetch = async (url, options) => {
  assert.equal(url, '/api/web/search?q=Artist%20%26%20Song');
  assert.equal(options.cache, 'no-store');
  return new Response(JSON.stringify({ library: [serviceTrack], catalog: [song] }));
};
const combined = await webSearchApi.search('Artist & Song', new AbortController().signal);
assert.equal(combined.library[0].duration_seconds, 13);
assert.equal(combined.catalog[0].external_id, song.external_id);
for (const tracks of [[{ ...serviceTrack, owner_kind: 'user' }], [playbackTrack], [serviceTrack, serviceTrack]]) {
  globalThis.fetch = async () => new Response(JSON.stringify({ library: tracks, catalog: [] }));
  await assert.rejects(webSearchApi.search('Song', new AbortController().signal));
}
console.log('PASS: catalog validation, recording names, unsafe URLs, query encoding, cookie sessions, provider/ID selection and cancellation.');

const { tracksApi } = await import(moduleUrl(new URL('../../src/features/tracks/api.ts', import.meta.url)));
const personalTrack = { ...serviceTrack, owner_kind: 'user' };
globalThis.fetch = async (url) => {
  assert.equal(url, '/api/tracks/search?q=Personal');
  return new Response(JSON.stringify({ tracks: [{ track: personalTrack, playlist_id: playbackTrack.owner_id }] }));
};
const matches = await tracksApi.searchLibrary('Personal', new AbortController().signal);
assert.equal(matches[0].playlistId, playbackTrack.owner_id);
assert.equal(matches[0].track.id, personalTrack.id);
for (const tracks of [
  [{ track: serviceTrack, playlist_id: playbackTrack.owner_id }],
  [{ track: personalTrack, playlist_id: 'invalid' }],
  [{ track: personalTrack, playlist_id: playbackTrack.owner_id }, { track: personalTrack, playlist_id: playbackTrack.owner_id }],
]) {
  globalThis.fetch = async () => new Response(JSON.stringify({ tracks }));
  await assert.rejects(tracksApi.searchLibrary('Personal', new AbortController().signal));
}

const { track: parseTrack } = await import(moduleUrl(new URL('../../src/features/tracks/model.ts', import.meta.url)));
assert.equal(parseTrack(personalTrack).owner_kind, 'user');
assert.equal(parseTrack(serviceTrack).owner_kind, 'system');
assert.equal(parseTrack({ ...personalTrack, owner_id: null, owner_kind: null }).owner_kind, null);
for (const invalid of [
  { ...personalTrack, owner_kind: undefined },
  { ...personalTrack, owner_kind: 'admin' },
  { ...personalTrack, owner_kind: true },
  { ...personalTrack, owner_kind: null },
  { ...personalTrack, owner_id: null },
]) assert.throws(() => parseTrack(invalid));
