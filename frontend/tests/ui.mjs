import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { chromium } from 'playwright';

// API fixtures isolate browser checks from the user's music and PostgreSQL.
const base = process.env.UI_TEST_URL || 'http://127.0.0.1:5173';
mkdirSync('../backend/.zig-cache', { recursive: true });
const temporary = mkdtempSync(join(tmpdir(), 'musica-ui-'));
const ffmpeg = process.env.FFMPEG_PATH || 'ffmpeg';
const converted = spawnSync(ffmpeg, ['-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=13',
  '-c:a', 'aac', '-f', 'hls', '-hls_time', '6', '-hls_playlist_type', 'vod', '-hls_segment_filename',
  join(temporary, 'segment-%06d.ts'), join(temporary, 'index.m3u8')]);
assert.equal(converted.status, 0, `FFmpeg required for playback checks: ${converted.error || converted.stderr}`);
const edge = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const executablePath = process.env.CHROMIUM_PATH || (existsSync(edge) ? edge : undefined);
const browser = await chromium.launch({ executablePath, headless: true });
const id = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const user = { id: id(1), username: 'music_lover', default_playlist_id: id(2) };
const metadata = (n, title, isDefault = false) => ({ id: id(n), owner_id: user.id, title, description: '',
  visibility: 'private', is_default: isDefault, image_key: null, role: 'owner', track_count: 0 });
const tracks = [
  { id: id(10), owner_id: user.id, title: 'Midnight City', artist: 'M83', status: 'streamed' },
  { id: id(11), owner_id: user.id, title: 'Weightless', artist: 'Marconi Union', status: 'streamed' },
  { id: id(12), owner_id: user.id, title: '<img src=x onerror=alert(1)>', artist: 'Test', status: 'pending' },
];
let playlists = [metadata(2, 'Uploads', true), metadata(3, 'Тихие вечера'), metadata(4, 'В дороге')];
const members = new Map([[id(2), [...tracks]], [id(3), [tracks[0]]], [id(4), [tracks[1]]]]);
const mutations = [];
let authenticated = true;
let nextId = 20;
const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, serviceWorkers: 'block' });
const page = await context.newPage();
const errors = [];
page.on('pageerror', (error) => errors.push(error.message));
await page.route('**/api/**', async (route) => {
  const request = route.request(); const path = new URL(request.url()).pathname;
  const method = request.method(); const json = (data, status = 200) => route.fulfill({ status, contentType: 'application/json', headers: { 'Cache-Control': 'no-store' }, body: JSON.stringify(data) });
  if (path === '/api/users/me') return authenticated ? json(user) : json({ error: 'unauthorized' }, 401);
  if (path === '/api/auth/login' || path === '/api/auth/register') { authenticated = true; return json({ user_id: user.id, token: 'a'.repeat(64) }, path.endsWith('register') ? 201 : 200); }
  if (path === '/api/auth/logout') { authenticated = false; return route.fulfill({ status: 204 }); }
  if (method !== 'GET') mutations.push({ method, path, body: request.headers()['content-type']?.includes('application/json') ? request.postDataJSON() : request.postData() });
  if (path === '/api/playlists' && method === 'GET') return json(playlists.map((p) => ({ ...p, track_count: members.get(p.id).length })));
  if (path === '/api/playlists' && method === 'POST') {
    const p = { ...metadata(nextId++, ''), ...request.postDataJSON() }; playlists.push(p); members.set(p.id, []); return json({ id: p.id }, 201);
  }
  let match = path.match(/^\/api\/playlists\/([^/]+)$/);
  if (match && method === 'GET') return json({ ...playlists.find((p) => p.id === match[1]), tracks: members.get(match[1]) });
  match = path.match(/^\/api\/playlists\/([^/]+)\/tracks\/([^/]+)$/);
  if (match) {
    if (method === 'DELETE') members.set(match[1], members.get(match[1]).filter((t) => t.id !== match[2]));
    else if (!members.get(match[1]).some((t) => t.id === match[2])) members.get(match[1]).push(tracks.find((t) => t.id === match[2]));
    return route.fulfill({ status: 204 });
  }
  if (path === '/api/tracks' && method === 'POST') {
    const body = request.postDataJSON(); const t = { id: id(nextId++), title: body.title, artist: body.artist, owner_id: user.id, status: 'pending' };
    tracks.push(t); for (const p of new Set([id(2), ...body.playlist_ids])) members.get(p).push(t);
    return json({ id: t.id, status: t.status }, 201);
  }
  match = path.match(/^\/api\/tracks\/([^/]+)(.*)$/);
  if (match) {
    const t = tracks.find((t) => t.id === match[1]);
    if (method === 'DELETE') { for (const [key, list] of members) members.set(key, list.filter((t) => t.id !== match[1])); return route.fulfill({ status: 204 }); }
    if (match[2] === '/file') { t.status = 'ready'; return json({ status: t.status }); }
    if (match[2] === '/hls' && method === 'POST') { t.status = 'streamed'; return json({ status: 'streamed', preparation: 'ready' }); }
    if (match[2] === '/hls/status') return json({ status: t.status, preparation: t.status === 'pending' ? null : 'ready' });
    if (match[2] === '/hls/index.m3u8') return route.fulfill({ contentType: 'application/vnd.apple.mpegurl', body: readFileSync(join(temporary, 'index.m3u8')) });
    if (/^\/hls\/segment-\d{6}\.ts$/.test(match[2])) return route.fulfill({ contentType: 'video/mp2t', body: readFileSync(join(temporary, match[2].split('/').at(-1))) });
  }
  return json({ error: 'not_found' }, 404);
});
const overflow = async () => assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth), false, 'horizontal overflow');
try {
  await page.goto(base); await page.locator('h1').filter({ hasText: 'Uploads' }).waitFor();
  await overflow(); assert.equal(await page.locator('.track-row').count(), 3);
  assert.equal(await page.locator('.track-title img').count(), 0, 'track title must be escaped');
  await page.locator('#search').fill('m83'); assert.equal(await page.locator('.track-row').count(), 1);
  await page.locator('#search').fill('nothing matches'); await page.getByRole('heading', { name: 'Ничего не нашлось' }).waitFor();
  await page.locator('#search').fill(''); await page.locator(`[data-play="${id(10)}"]`).click();
  await page.locator('#player-play[aria-label="Пауза"]').waitFor();
  assert.equal(await page.locator('#now-title').textContent(), 'Midnight City');
  await page.waitForFunction(() => document.querySelector('#elapsed').textContent !== '0:00');
  await page.locator('#player-play').click(); await page.locator('#player-play[aria-label="Воспроизвести"]').waitFor();
  await page.screenshot({ path: '../backend/.zig-cache/ui-desktop.png' });
  await page.locator(`.sidebar [data-playlist="${id(3)}"]`).click(); await page.getByRole('heading', { name: 'Тихие вечера' }).waitFor();
  await page.locator(`[data-track-menu="${id(10)}"]`).click(); await page.locator('#remove-track').click();
  assert.match(await page.locator('#confirm-description').textContent(), /останется в Uploads/);
  await page.locator('#confirm-delete').click(); await page.getByRole('heading', { name: 'Начните свою коллекцию' }).waitFor();
  assert.equal(members.get(id(2)).length, 3); assert.equal(mutations.at(-1).path, `/api/playlists/${id(3)}/tracks/${id(10)}`);
  await page.locator(`.sidebar [data-playlist="${id(2)}"]`).click(); await page.getByRole('heading', { name: 'Uploads', exact: true }).waitFor();
  await page.locator(`[data-track-menu="${id(10)}"]`).click(); await page.locator('#remove-track').click();
  assert.match(await page.locator('#confirm-description').textContent(), /всех плейлистов/);
  await page.locator('#confirm-delete').click(); await page.waitForFunction(() => document.querySelectorAll('.track-row').length === 2);
  assert.equal(mutations.at(-1).path, `/api/tracks/${id(10)}`);
  assert.equal(await page.locator('#now-title').textContent(), 'Выберите трек');
  await page.locator('.topbar [data-action="upload"]').click();
  await page.locator('#file-input').setInputFiles([{ name: 'Artist - New song.mp3', mimeType: 'audio/mpeg', buffer: Buffer.from('mock audio') }, { name: 'Other.flac', mimeType: 'audio/flac', buffer: Buffer.from('mock flac') }]);
  assert.equal(await page.locator('[data-upload-title]').first().inputValue(), 'New song');
  await page.locator('[data-upload-artist]').first().fill('Edited artist');
  await page.screenshot({ path: '../backend/.zig-cache/ui-upload.png' });
  await page.locator('#start-upload').click(); await page.locator('.upload-item.done').nth(1).waitFor();
  assert.equal(mutations.filter((m) => m.path === '/api/tracks').length, 2);
  assert.equal(tracks.find((t) => t.title === 'New song').artist, 'Edited artist');
  await page.locator('#upload-dialog [data-close]').click();
  await page.locator('.sidebar [data-action="new-playlist"]').click();
  await page.locator('#playlist-form [name="title"]').fill('Новый плейлист');
  await page.locator('#playlist-form button').click(); await page.getByRole('heading', { name: 'Новый плейлист', exact: true }).waitFor();
  for (const viewport of [{ width: 390, height: 844 }, { width: 320, height: 568 }]) {
    await page.setViewportSize(viewport); await overflow();
    assert.equal(await page.locator('.topbar [data-action="upload"]').isVisible(), false);
    await page.locator('#open-library').click(); await page.locator(`#library-dialog [data-playlist="${id(2)}"]`).click();
    await page.getByRole('heading', { name: 'Uploads', exact: true }).waitFor();
    assert.equal(await page.locator('#library-dialog').isVisible(), false);
    await page.screenshot({ path: `../backend/.zig-cache/ui-mobile-${viewport.width}.png` });
  }
  authenticated = false; await page.reload(); await page.locator('#auth-dialog[open]').waitFor(); await overflow();
  await page.locator('#auth-form [name="username"]').fill('music_lover');
  await page.locator('#auth-form [name="password"]').fill('test-password-123');
  await page.locator('#auth-submit').click(); await page.getByRole('heading', { name: 'Uploads', exact: true }).waitFor();
  assert.deepEqual(errors, []);
  console.log('PASS: desktop/mobile layouts, search, escaped metadata, actual AAC HLS playback, upload queue, playlists, auth and both deletion modes.');
} finally { await browser.close(); rmSync(temporary, { recursive: true, force: true }); }
