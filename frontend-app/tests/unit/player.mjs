import assert from 'node:assert/strict';
import { moduleUrl } from '../helpers/typescript.mjs';

class AudioFixture extends EventTarget {
  paused = true;
  currentTime = 0;
  duration = 60;
  volume = 1;
  muted = false;
  src = '';
  canPlayType() { return 'probably'; }
  play() { this.paused = false; this.dispatchEvent(new Event('play')); return Promise.resolve(); }
  pause() { this.paused = true; this.dispatchEvent(new Event('pause')); }
  load() { this.dispatchEvent(new Event('emptied')); }
  removeAttribute(name) { if (name === 'src') this.src = ''; }
}
globalThis.Audio = AudioFixture;
const preferences = new Map();
globalThis.localStorage = {
  getItem: key => preferences.get(key) ?? null,
  setItem: (key, value) => preferences.set(key, value),
};
if (!globalThis.navigator) globalThis.navigator = {};
const { PlayerEngine } = await import(moduleUrl(new URL('../../src/features/player/engine.ts', import.meta.url)));
const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const track = n => ({ id: id(n), owner_kind: 'user', owner_id: id(1), title: `Track ${n}`, artist: 'Artist', status: 'streamed' });
const [first, second, third] = [track(10), track(11), track(12)];
let changes = 0;
const notices = [];
const engine = new PlayerEngine(() => { changes++; }, message => notices.push(message), () => id(1), () => 'a'.repeat(64));
await engine.load(first, [first, second]);
assert.equal(engine.snapshot().paused, false);
assert.match(engine.audio.src, /share_token=a{64}$/);
engine.enqueue(third, true);
engine.enqueue(third, true);
assert.deepEqual(engine.upcoming.map(item => item.id), [third.id, second.id], 'next insertion is ordered and deduplicated');
engine.removeQueued(third.id);
assert.deepEqual(engine.upcoming.map(item => item.id), [second.id]);
engine.next();
assert.equal(engine.current.id, second.id);
engine.volume(35); engine.mute();
assert.equal(engine.snapshot().muted, true);
assert.equal(engine.snapshot().volume, 35);
const restored = new PlayerEngine(() => {}, () => {}, () => id(1), () => null);
assert.equal(restored.snapshot().volume, 35, 'volume survives a new player instance');
assert.equal(restored.snapshot().muted, true, 'mute is restored without losing volume');
restored.mute();
assert.equal(restored.snapshot().muted, false);
assert.equal(restored.snapshot().volume, 35);
restored.volume(0);
const silent = new PlayerEngine(() => {}, () => {}, () => id(1), () => null);
assert.equal(silent.snapshot().volume, 0, 'stored zero is distinct from an absent preference');
silent.dispose(); restored.dispose();
for (const invalid of ['NaN', '101', '-1', '', 'garbage']) {
  preferences.set('musica:volume', invalid);
  const fallback = new PlayerEngine(() => {}, () => {}, () => id(1), () => null);
  assert.equal(fallback.snapshot().volume, 100, 'invalid volume falls back to the audio default');
  fallback.dispose();
}
engine.mute();
assert.equal(engine.snapshot().volume, 35, 'unmuting restores volume');
engine.volume(NaN);
assert.equal(engine.snapshot().volume, 35, 'invalid input does not overwrite the volume');
engine.seek(500);
assert.equal(engine.audio.currentTime, 30);
engine.previous();
assert.equal(engine.audio.currentTime, 0, 'previous restarts a track after the first three seconds');
engine.enqueue(third);
const beforeRemoval = changes;
engine.remove(third.id);
assert.ok(changes > beforeRemoval, 'removing a queued track updates a paused UI too');

const sourceBeforeMetadata = engine.audio.src;
const elapsedBeforeMetadata = engine.audio.currentTime;
engine.enqueue(third);
const queueBeforeMetadata = engine.upcoming.map(item => item.id);
const updated = { ...engine.current, artwork_key: 'tracks/artwork/new.jpg', duration_seconds: 60 };
const updatedQueued = { ...third, artwork_key: 'tracks/artwork/queued.jpg' };
engine.updateMetadata([updated, updatedQueued]);
assert.equal(engine.current.artwork_key, updated.artwork_key);
assert.equal(engine.upcoming.find(item => item.id === third.id).artwork_key, updatedQueued.artwork_key);
assert.equal(engine.audio.src, sourceBeforeMetadata, 'metadata updates must not reload audio');
assert.equal(engine.audio.currentTime, elapsedBeforeMetadata);
assert.deepEqual(engine.upcoming.map(item => item.id), queueBeforeMetadata);

const { trackArtworkUrl } = await import(moduleUrl(new URL('../../src/features/tracks/image.ts', import.meta.url)));
assert.equal(trackArtworkUrl(first), null, 'missing artwork does not make a request');
const artworkUrl = new URL(trackArtworkUrl(updated, 'a'.repeat(64)), 'http://localhost');
assert.equal(artworkUrl.pathname, `/api/tracks/${updated.id}/artwork`);
assert.equal(artworkUrl.searchParams.get('v'), updated.artwork_key);
assert.equal(artworkUrl.searchParams.get('share_token'), 'a'.repeat(64));

let release;
const waiting = new Promise(resolve => { release = resolve; });
globalThis.fetch = async () => { await waiting; return new Response(JSON.stringify({ status: 'streamed', preparation: 'completed' }), { headers: { 'Content-Type': 'application/json' } }); };
const loading = engine.load({ ...first, status: 'ready' }, [first]);
engine.stop(); release(); await loading;
assert.equal(engine.current, null, 'a stale preparation result cannot restart a stopped player');
assert.equal(engine.audio.src, '');
assert.deepEqual(notices, []);
engine.dispose();
const afterDispose = changes;
engine.audio.dispatchEvent(new Event('timeupdate'));
assert.equal(changes, afterDispose, 'disposing removes audio subscriptions');

const interruptedNotices = [];
const interrupted = new PlayerEngine(() => {}, message => interruptedNotices.push(message), () => id(1), () => null);
const normalPlay = interrupted.audio.play.bind(interrupted.audio);
let attempts = 0;
interrupted.audio.play = () => {
  if (++attempts === 1) return Promise.reject(new DOMException('Source changed', 'AbortError'));
  return normalPlay();
};
await interrupted.load(first, [first]);
await new Promise(resolve => setImmediate(resolve));
assert.equal(interrupted.snapshot().paused, true);
interrupted.audio.dispatchEvent(new Event('canplay'));
await new Promise(resolve => setImmediate(resolve));
assert.equal(interrupted.snapshot().paused, false, 'an interrupted first play retries when media becomes playable');
assert.deepEqual(interruptedNotices, [], 'a loading interruption does not ask for a second click');
interrupted.toggle();
interrupted.audio.dispatchEvent(new Event('canplay'));
assert.equal(interrupted.snapshot().paused, true, 'canplay must not resume a track paused by the user');
interrupted.dispose();
const deferredNotices = [];
const deferred = new PlayerEngine(() => {}, message => deferredNotices.push(message), () => id(1), () => null);
let releaseDownload;
let downloadSignal;
const deferredLoad = deferred.loadDeferred(signal => {
  downloadSignal = signal;
  return new Promise(resolve => { releaseDownload = resolve; });
});
assert.equal(deferred.loading, true, 'waiting for a download is visible immediately');
await deferred.load(second, [second]);
assert.equal(downloadSignal.aborted, true, 'selecting another track cancels the waiting request');
releaseDownload(first);
await deferredLoad;
assert.equal(deferred.current.id, second.id, 'an older download must not replace the selected track');
let preparationReads = 0;
globalThis.fetch = async (url, options) => {
  assert.equal(options.method, undefined, 'service-owned tracks wait for automatic HLS preparation');
  preparationReads++;
  return new Response(JSON.stringify(preparationReads === 1
    ? { status: 'ready', preparation: null }
    : { status: 'streamed', preparation: 'completed' }), { headers: { 'Content-Type': 'application/json' } });
};
await deferred.loadDeferred(async () => ({ ...first, status: 'ready', owner_id: id(99), owner_kind: 'system' }));
assert.equal(deferred.current.id, first.id);
assert.equal(deferred.snapshot().paused, false, 'a downloaded service-owned track starts automatically');
assert.deepEqual(deferredNotices, []);
deferred.dispose();
console.log('PASS: native audio playback, shared tokens, ordered queue, mute/seek, cancellation and lifecycle cleanup.');
