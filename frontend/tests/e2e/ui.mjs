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
const updatedImage = spawnSync(ffmpeg, ['-v', 'error', '-f', 'lavfi', '-i', 'color=c=blue:s=16x16',
  '-frames:v', '1', join(temporary, 'updated-cover.png')]);
assert.equal(updatedImage.status, 0, 'FFmpeg generates a distinct replacement cover');
const updatedImageBytes = readFileSync(join(temporary, 'updated-cover.png'));
const edge = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const executablePath = process.env.CHROMIUM_PATH || (existsSync(edge) ? edge : undefined);
const browser = await chromium.launch({ executablePath, headless: true });
const id = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const user = { id: id(1), username: 'music_lover', default_playlist_id: id(2) };
const metadata = (n, title, isDefault = false) => ({ id: id(n), owner_id: user.id, title, description: '',
  tags: ['ambient'], visibility: 'private', is_default: isDefault, image_key: null, role: 'owner', track_count: 0 });
const tracks = [
  { id: id(10), owner_id: user.id, title: 'Midnight City', artist: 'M83', status: 'streamed', artwork_key: 'tracks/first/artwork/initial.jpg' },
  { id: id(11), owner_id: user.id, title: 'Weightless', artist: 'Marconi Union', status: 'streamed', artwork_key: 'missing.jpg' },
  { id: id(12), owner_id: user.id, title: '<img src=x onerror=alert(1)>', artist: 'Test', status: 'pending' },
];
let playlists = [metadata(2, 'Uploads', true), metadata(3, 'Тихие вечера'), metadata(4, 'В дороге')];
const members = new Map([[id(2), [...tracks]], [id(3), [tracks[0]]], [id(4), [tracks[1]]]]);
const mutations = [];
let authenticated = true;
let nextId = 20;
let failImage = false;
let failLibrary = false;
let expireLibrary = false;
let libraryDelay = 0;
let manifestRequests = 0;
let holdMe = false;
let releaseMe;
let meHeld;
let verifyPlaybackCookie = false;
const playbackCookies = [];
const imageBytes = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aS1sAAAAASUVORK5CYII=', 'base64');
const playlistImages = new Map();
let imageVersion = 0;
const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, serviceWorkers: 'block' });
await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: base });
const page = await context.newPage();
const errors = [];
page.on('pageerror', (error) => { errors.push(error.message); console.error(error.message); });
await page.route('**/api/**', async (route) => {
  const request = route.request(); const path = new URL(request.url()).pathname;
  if (!path.startsWith('/api/')) return route.continue();
  const method = request.method(); const json = (data, status = 200) => route.fulfill({ status, contentType: 'application/json', headers: { 'Cache-Control': 'no-store' }, body: JSON.stringify(data) });
  if (path === '/api/users/me') {
    if (holdMe) {
      holdMe = false;
      const waiting = new Promise(resolve => { releaseMe = resolve; });
      meHeld();
      await waiting;
      return json({ error: 'unauthorized' }, 401);
    }
    return authenticated ? json(user) : json({ error: 'unauthorized' }, 401);
  }
  if (path === '/api/auth/login' || path === '/api/auth/register') {
    if (request.postDataJSON().password === 'wrong-password-123') return json({ error: 'unauthorized' }, 401);
    authenticated = true;
    return route.fulfill({ status: path.endsWith('register') ? 201 : 200,
      contentType: 'application/json', headers: { 'Set-Cookie': `musica_session=${'b'.repeat(64)}; Path=/api; HttpOnly; SameSite=Strict` },
      body: JSON.stringify({ user_id: user.id }) });
  }
  if (path === '/api/auth/logout') { authenticated = false; return route.fulfill({ status: 204 }); }
  if (method !== 'GET') mutations.push({ method, path, body: request.headers()['content-type']?.includes('application/json') ? request.postDataJSON() : request.postData() });
  if (path === '/api/playlists' && method === 'GET') {
    if (expireLibrary) return json({ error: 'unauthorized' }, 401);
    if (failLibrary) return json({ error: 'internal_error' }, 500);
    if (libraryDelay) await new Promise(resolve => setTimeout(resolve, libraryDelay));
    return json(playlists.map((p) => ({ ...p, track_count: members.get(p.id).length })));
  }
  if (path === `/api/playlists/${id(3)}/share-link` && method === 'POST') return json({ path: '/api/shared/playlists/' + 'a'.repeat(64) });
  if (path === '/api/shared/playlists/' + 'a'.repeat(64)) return json({ ...playlists.find(p => p.id === id(3)), tracks: members.get(id(3)) });
  if (path === '/api/spotify/import' && method === 'POST') {
    const input = request.postDataJSON();
    assert.equal(input.playlists[0].title, 'Spotify mix');
    assert.equal(input.library[0].spotify_uri, input.playlists[0].tracks[0].spotify_uri);
    const p = metadata(nextId++, input.playlists[0].title); playlists.push(p);
    const t = { id: id(nextId++), owner_id: user.id, title: input.library[0].title, artist: input.library[0].artist, status: 'pending' };
    tracks.push(t); members.get(id(2)).push(t); members.set(p.id, [t]);
    return json({ tracks: 1, playlists: [p.id] }, 202);
  }
  if (path === '/api/playlists' && method === 'POST') {
    const p = { ...metadata(nextId++, ''), ...request.postDataJSON() }; playlists.push(p); members.set(p.id, []); return json({ id: p.id }, 201);
  }
  let match = path.match(/^\/api\/playlists\/([^/]+)\/image$/);
  if (match) {
    if (method === 'GET') return route.fulfill({ contentType: 'image/png', body: playlistImages.get(match[1]) ?? imageBytes });
    if (failImage) { failImage = false; return json({ error: 'internal_error' }, 500); }
    const p = playlists.find(p => p.id === match[1]); p.image_key = `playlists/${p.id}/cover-${++imageVersion}`;
    playlistImages.set(p.id, request.postDataBuffer());
    return json({ image_key: p.image_key, bucket: 'uploads' });
  }
  match = path.match(/^\/api\/playlists\/([^/]+)$/);
  if (match && method === 'PUT') { Object.assign(playlists.find(p => p.id === match[1]), request.postDataJSON()); return route.fulfill({ status: 204 }); }
  if (match && method === 'DELETE') { playlists = playlists.filter(p => p.id !== match[1]); members.delete(match[1]); return route.fulfill({ status: 204 }); }

  if (match && method === 'GET') {
    if (expireLibrary) return json({ error: 'unauthorized' }, 401);
    const p = playlists.find((p) => p.id === match[1]);
    if (!authenticated && p.visibility !== 'public') return json({ error: 'unauthorized' }, 401);
    return json({ ...p, tracks: members.get(match[1]) });
  }
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
    if (verifyPlaybackCookie && match[2].startsWith('/hls')) {
      const cookie = request.headers().cookie ?? '';
      playbackCookies.push({ path, cookie });
      if (!cookie.includes(`musica_session=${'b'.repeat(64)}`)) return json({ error: 'unauthorized' }, 401);
    }
    const t = tracks.find((t) => t.id === match[1]);
    if (match[2] === '/artwork') {
      if (!t?.artwork_key || t.artwork_key === 'missing.jpg') return json({ error: 'not_found' }, 404);
      return route.fulfill({ contentType: 'image/png', body: imageBytes });
    }
    if (method === 'DELETE') { for (const [key, list] of members) members.set(key, list.filter((t) => t.id !== match[1])); return route.fulfill({ status: 204 }); }
    if (match[2] === '/file') { t.status = 'ready'; return json({ status: t.status }); }
    if (match[2] === '/hls' && method === 'POST') { t.status = 'streamed'; return json({ status: 'streamed', preparation: 'completed' }); }
    if (match[2] === '/hls/status') return json({ status: t.status, preparation: t.status === 'pending' ? null : 'completed' });
    if (match[2] === '/hls/index.m3u8') {
      manifestRequests++;
      await new Promise(resolve => setTimeout(resolve, 250));
      return route.fulfill({ contentType: 'application/vnd.apple.mpegurl', body: readFileSync(join(temporary, 'index.m3u8')) });
    }
    if (/^\/hls\/segment-\d{6}\.ts$/.test(match[2])) return route.fulfill({ contentType: 'video/mp2t', body: readFileSync(join(temporary, match[2].split('/').at(-1))) });
  }
  return json({ error: 'not_found' }, 404);
});
const toggleTheme = async () => { await page.locator('#profile-toggle').click(); await page.locator('#theme-toggle').click(); await page.keyboard.press('Escape'); };
const openSpotify = async () => { if (await page.locator('.sidebar').isVisible()) await page.locator('.topbar [data-action=upload]').click(); else { await page.locator('#open-library').click(); await page.locator('#library-dialog [data-action=upload]').click(); } await page.locator('#upload-dialog [data-action=spotify-import]').click(); };
const overflow = async () => assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth), false, 'horizontal overflow');
try {
  await page.goto(base);
  await page.locator('h1').filter({ hasText: 'Uploads' }).waitFor({ timeout: 10000 }).catch(async error => { console.error('Startup UI:', await page.locator('body').innerText()); throw error; });
  await overflow(); assert.equal(await page.locator('.track-row').count(), 3);
  failLibrary = true;
  await page.reload();
  await page.getByRole('heading', { name: 'Не удалось загрузить плейлист', exact: true }).waitFor();
  assert.equal(await page.locator('#auth-dialog').isVisible(), false, 'playlist failure does not reopen login for an authenticated user');
  assert.equal(await page.locator('.auth-placeholder').count(), 0);
  failLibrary = false;
  libraryDelay = 300;
  await page.locator('#retry-playlist').click();
  await page.getByText('Загрузка плейлиста…', { exact: true }).waitFor();
  await page.getByRole('heading', { name: 'Uploads', exact: true }).waitFor();
  libraryDelay = 0;
  assert.equal(await page.locator('html').getAttribute('data-theme'), 'dark');
  assert.equal(await page.locator('.now-playing').isVisible(), false, 'no placeholder track when nothing is selected');
  assert.equal(await page.locator('#refresh').count(), 0);
  assert.equal(await page.locator('#playlist-menu-toggle').count(), 0);
  assert.equal(await page.locator('.collection-toolbar button').count(), 2);
  assert.equal(await page.locator('.track-favorite').count(), 0);
  assert.equal(await page.locator('.collection-toolbar .round-button[disabled]').count(), 0);
  assert.equal(await page.locator('.track-row .track-length').first().textContent(), '—:—');
  assert.equal(await page.locator('.sidebar').evaluate(el => getComputedStyle(el).borderTopLeftRadius), '22px');
  await page.locator('#volume').evaluate(input => {
    input.value = '37';
    input.dispatchEvent(new Event('input', { bubbles: true }));
  });
  await page.locator('#mute').click(); assert.equal(await page.locator('#mute').getAttribute('aria-pressed'), 'true');
  assert.equal(await page.locator('#volume').inputValue(), '0', 'mute moves the slider to zero');
  assert.equal(await page.locator('#volume').evaluate(input => input.style.getPropertyValue('--progress')), '0%', 'mute empties the volume bar');
  await page.locator('#mute').click(); assert.equal(await page.locator('#mute').getAttribute('aria-pressed'), 'false');
  assert.equal(await page.locator('#volume').inputValue(), '37', 'unmute restores the same level');
  assert.equal(await page.locator('#volume').evaluate(input => input.style.getPropertyValue('--progress')), '37%', 'unmute restores the filled volume bar');
  await page.locator('.sidebar [data-playlist]').first().click({ button: 'right' });
  assert.equal(await page.locator('#delete-playlist').isDisabled(), true, 'Uploads cannot be deleted');
  assert.equal(await page.locator('#edit-playlist').isDisabled(), true, 'Uploads settings cannot be edited');
  assert.equal(await page.locator('#share-playlist').isDisabled(), true, 'Uploads cannot be shared');
  assert.equal(await page.locator('#context-menu button svg').count(), await page.locator('#context-menu button').count(), 'each menu action has an icon');
  assert.ok(await page.locator('#context-menu [role=separator]').count() > 0, 'menu actions are grouped');
  await page.keyboard.press('Escape');

  await page.locator(`.sidebar [data-playlist="${id(3)}"]`).click({ button: 'right' });
  assert.equal(await page.locator('#share-playlist').isDisabled(), true, 'sharing does not change private access');
  await page.keyboard.press('Escape');
  playlists.find(p => p.id === id(3)).visibility = 'unlisted';
  await page.reload(); await page.getByRole('heading', { name: 'Uploads', exact: true }).waitFor();
  await page.locator(`.sidebar [data-playlist="${id(3)}"]`).click({ button: 'right' });
  await page.locator('#share-playlist').click();
  await page.waitForFunction(() => document.querySelector('#toast').textContent === 'Ссылка скопирована');
  const sharedUrl = await page.evaluate(() => navigator.clipboard.readText());
  assert.equal(new URL(sharedUrl).hash, '#share=' + 'a'.repeat(64));
  await page.locator(`.sidebar [data-playlist="${id(3)}"]`).click({ button: 'right' }); await page.locator('#share-playlist').click();
  await page.waitForFunction(() => document.querySelector('#context-menu').hidden);
  assert.equal(mutations.filter(m => m.path.endsWith('/share-link')).length, 1, 'repeat copying keeps the same token');
  authenticated = false; await page.goto(sharedUrl);
  await page.getByRole('heading', { name: 'Тихие вечера', exact: true }).waitFor();
  assert.equal(await page.locator('#auth-dialog').getAttribute('open'), null, 'shared link opens without login');
  const sharedManifest = page.waitForRequest(request => request.url().includes('/hls/index.m3u8?share_token='));
  await page.locator('#playlist-play').click();
  assert.equal(new URL((await sharedManifest).url()).searchParams.get('share_token'), 'a'.repeat(64));
  authenticated = true; playlists.find(p => p.id === id(3)).visibility = 'public';
  await page.goto(base); await page.getByRole('heading', { name: 'Uploads', exact: true }).waitFor();
  await page.locator(`.sidebar [data-playlist="${id(3)}"]`).click({ button: 'right' }); await page.locator('#share-playlist').click();
  await page.waitForFunction(() => document.querySelector('#toast').textContent === 'Ссылка скопирована');
  const publicUrl = await page.evaluate(() => navigator.clipboard.readText());
  assert.equal(new URL(publicUrl).searchParams.get('playlist'), id(3));
  authenticated = false; await page.goto(publicUrl);
  await page.getByRole('heading', { name: 'Тихие вечера', exact: true }).waitFor();
  assert.equal(await page.locator('#auth-dialog').getAttribute('open'), null);
  authenticated = true; playlists.find(p => p.id === id(3)).visibility = 'private';
  await page.goto(base); await page.getByRole('heading', { name: 'Uploads', exact: true }).waitFor();

  // An old /users/me response must not clear a newer session or its playlist.
  const held = new Promise(resolve => { meHeld = resolve; });
  holdMe = true;
  await page.evaluate(() => { location.hash = 'share=' + 'a'.repeat(64); });
  await held;
  const newSession = page.waitForResponse(response => response.url().endsWith('/api/users/me') && response.status() === 200);
  await page.evaluate(() => { location.hash = 'share=' + 'a'.repeat(64) + '&retry=1'; });
  await newSession;
  await page.getByRole('heading', { name: playlists.find(p => p.id === id(3)).title, exact: true }).waitFor();
  const staleResponse = page.waitForResponse(response => response.url().endsWith('/api/users/me') && response.status() === 401);
  releaseMe();
  await staleResponse;
  await page.waitForTimeout(100);
  assert.equal(await page.locator('.auth-placeholder').count(), 0, 'a stale auth failure cannot reset the new session');
  assert.equal(await page.locator('.avatar-label').textContent(), 'M');
  assert.equal(await page.locator('.track-row').count(), 1, 'a stale auth failure cannot clear the playlist');
  await page.goto(base); await page.getByRole('heading', { name: 'Uploads', exact: true }).waitFor();

  await page.locator('#volume').fill('35');
  assert.equal(await page.locator('#volume').evaluate(el => el.style.getPropertyValue('--progress')), '35%');
  assert.match(await page.locator('#volume').evaluate(el => getComputedStyle(el).backgroundImage), /35%/);
  assert.match(await page.locator('.hero-facts').textContent(), /3 треков, — ч/);
  assert.equal(await page.evaluate(() => {
    const top = document.querySelector('.topbar').getBoundingClientRect();
    const sidebar = document.querySelector('.sidebar').getBoundingClientRect();
    const main = document.querySelector('#collection').getBoundingClientRect();
    const bottom = document.querySelector('.player').getBoundingClientRect();
    return top.left === 8 && top.right === innerWidth - 8 && sidebar.top === top.bottom + 8 && main.top === sidebar.top && Math.abs(sidebar.bottom - (bottom.top - 8)) < 2 && main.bottom === sidebar.bottom;
  }), true, 'full-width header and player frame the middle panels: ' + await page.evaluate(() => JSON.stringify(['.topbar', '.sidebar', '#collection', '.player'].map(selector => ({ selector, rect: document.querySelector(selector).getBoundingClientRect().toJSON() })))));
  assert.equal(await page.locator('.topbar .brand').count(), 1);
  assert.equal(await page.locator('.sidebar .brand').count(), 0);
  assert.equal(await page.locator('.topbar .profile-info').count(), 0);
  const handle = page.locator('#sidebar-resize');
  const box = await handle.boundingBox(); await page.mouse.move(box.x + box.width / 2, 200); await page.mouse.down(); await page.mouse.move(340, 200); await page.mouse.up();
  assert.equal(await handle.getAttribute('aria-valuenow'), '340'); await overflow();
  await handle.focus(); await page.keyboard.press('Home');
  assert.equal(await handle.getAttribute('aria-valuenow'), '104');
  assert.ok((await page.locator('.sidebar').boundingBox()).width >= 88, 'collapsed sidebar leaves space around covers');
  assert.equal(await page.locator('.sidebar .nav-cover').first().isVisible(), true);
  assert.equal(await page.locator('.sidebar .playlist-link strong').first().isVisible(), false);
  await page.screenshot({ path: '../backend/.zig-cache/ui-sidebar-collapsed.png' });
  await page.keyboard.press('End'); for (let n=0;n<6;n++) await page.keyboard.press('ArrowLeft');
  assert.equal(await handle.getAttribute('aria-valuenow'), '244');
  await page.setViewportSize({ width: 1440, height: 400 });
  const thumb = page.locator('.collection-scrollbar-thumb'); await thumb.waitFor();
  assert.ok((await thumb.boundingBox()).height <= 80, 'compact scrollbar thumb');
  await thumb.focus(); await page.keyboard.press('End');
  await page.waitForFunction(() => document.querySelector('.collection-scrollbar-thumb').getAttribute('aria-valuenow') === '100');
  await page.keyboard.press('Home');
  await page.waitForFunction(() => document.querySelector('#collection').scrollTop === 0);
  const railBox = await page.locator('.collection-scrollbar').boundingBox(); const thumbBox = await thumb.boundingBox();
  await page.mouse.move(thumbBox.x + 3, thumbBox.y + thumbBox.height / 2); await page.mouse.down(); await page.mouse.move(railBox.x + 3, railBox.y + railBox.height); await page.mouse.up();
  await page.waitForFunction(() => document.querySelector('.collection-scrollbar-thumb').getAttribute('aria-valuenow') === '100');
  await thumb.focus(); await page.keyboard.press('Home');
  const navBox = await page.locator('.sidebar .playlist-nav').boundingBox();
  await page.mouse.move(navBox.x + navBox.width / 2, navBox.y + navBox.height / 2); await page.mouse.wheel(0, 250);
  await page.waitForFunction(() => document.querySelector('.sidebar .playlist-nav').scrollTop > 0);
  await page.waitForFunction(() => !document.querySelector('.sidebar .playlist-nav').classList.contains('scrolling'));
  assert.equal(await page.locator('.sidebar .playlist-nav').evaluate(el => getComputedStyle(el).scrollbarColor), 'rgba(0, 0, 0, 0) rgba(0, 0, 0, 0)', 'scrollbar disappears when scrolling stops');
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.locator('#profile-toggle').click(); assert.equal(await page.locator('#profile-menu').isVisible(), true);
  await page.locator('#language').selectOption('en-US');
  assert.equal(await page.locator('html').getAttribute('lang'), 'en-US');
  assert.equal(await page.locator('#search').getAttribute('placeholder'), 'Search for songs or artists…');
  assert.equal(await page.locator('.sidebar .library-heading>span').textContent(), 'PLAYLISTS');
  assert.match(await page.locator('.hero-facts').textContent(), /3 tracks, — hours/);
  assert.equal(await page.locator('.sidebar .playlist-link strong').nth(1).textContent(), 'Тихие вечера', 'user metadata stays untranslated');
  await page.keyboard.press('Escape');
  await page.screenshot({ path: '../backend/.zig-cache/ui-english.png' });
  await page.reload(); await page.getByRole('heading', { name: 'Uploads', exact: true }).waitFor();
  assert.equal(await page.locator('html').getAttribute('lang'), 'en-US', 'language survives reload');
  assert.equal(await page.locator('#sidebar-resize').getAttribute('aria-valuenow'), '244', 'sidebar width survives reload');
  await page.locator('#profile-toggle').click(); await page.locator('#language').selectOption('ru-RU'); await page.keyboard.press('Escape');
  assert.equal(await page.locator('.sidebar .library-heading>span').textContent(), 'ПЛЕЙЛИСТЫ');

  await page.locator('.sidebar .playlist-search-input').fill('тихие');
  assert.equal(await page.locator('.sidebar [data-playlist]').count(), 1);
  await page.locator('.sidebar .playlist-search-input').fill('');
  await toggleTheme();
  assert.equal(await page.locator('html').getAttribute('data-theme'), 'light');
  await overflow();
  await page.screenshot({ path: '../backend/.zig-cache/ui-light-desktop.png' });
  await page.reload(); await page.getByRole('heading', { name: 'Uploads', exact: true }).waitFor();
  assert.equal(await page.locator('html').getAttribute('data-theme'), 'light', 'theme survives reload');
  await toggleTheme();
  assert.equal(await page.locator('.track-metadata img').count(), 0, 'track title must be escaped');
  await page.locator(`[data-track-row="${id(10)}"] .track-art img`).waitFor();
  await page.waitForFunction(() => !document.querySelector('[data-track-row="00000000-0000-4000-8000-000000000011"] .track-art img'));
  assert.equal(await page.locator(`[data-track-row="${id(12)}"] .track-art img`).count(), 0, 'tracks without artwork use a placeholder');
  const rowsBeforeSearch = await page.locator('.track-row').count();
  await page.locator('#search').fill('m83'); await page.locator('.search-result[data-source=local]').waitFor();
  await page.waitForFunction(() => document.querySelector('.search-result[data-source=local] img')?.naturalWidth > 0);
  assert.equal(await page.locator('.track-row').count(), rowsBeforeSearch, 'dropdown search leaves the playlist unchanged');
  await page.locator('#search').press('ArrowDown');
  assert.equal(await page.locator('.search-result-action').evaluate(element => element === document.activeElement), true);
  await page.keyboard.press('Enter');
  await page.locator('#search-results').waitFor({ state: 'detached' });
  await page.locator('#player-play[aria-label="Пауза"]').waitFor();
  assert.equal(await page.locator('#now-title').textContent(), 'Midnight City');
  await page.waitForFunction(() => document.querySelector('#now-art img')?.naturalWidth > 0);
  const artworkManifestRequests = manifestRequests;
  tracks[0].artwork_key = 'tracks/first/artwork/updated.jpg';
  await page.waitForFunction(() => document.querySelector('#now-art img')?.getAttribute('src')?.includes('updated.jpg'));
  assert.equal(manifestRequests, artworkManifestRequests, 'new artwork does not restart playback');
  const currentRow = page.locator(`[data-track-row="${id(10)}"]`);
  const rowPlay = currentRow.locator('.track-play');
  await rowPlay.filter({ has: page.locator('svg path[stroke-width="4"]') }).waitFor();
  assert.equal(await currentRow.getAttribute('aria-current'), 'true');
  assert.equal(await rowPlay.getAttribute('aria-label'), 'Пауза: Midnight City');
  assert.equal(await page.locator('#playlist-play').getAttribute('aria-label'), 'Пауза');
  const requestsBeforeToggle = manifestRequests;
  await rowPlay.click();
  await page.locator('#player-play[aria-label="Воспроизвести"]').waitFor();
  assert.equal(await rowPlay.getAttribute('aria-label'), 'Воспроизвести Midnight City');
  await page.locator('#playlist-play').click();
  await page.locator('#player-play[aria-label="Пауза"]').waitFor();
  await page.locator('#playlist-play').click();
  await page.locator('#player-play[aria-label="Воспроизвести"]').waitFor();
  await rowPlay.click();
  await page.locator('#player-play[aria-label="Пауза"]').waitFor();
  assert.equal(manifestRequests, requestsBeforeToggle, 'row and playlist toggles must not reload the current track');
  await page.locator('#profile-toggle').click(); await page.locator('#language').selectOption('en-US'); await page.keyboard.press('Escape');
  await page.locator('#player-play[aria-label="Pause"]').waitFor();
  assert.equal(await page.locator('#now-title').textContent(), 'Midnight City', 'language switch keeps the current track');
  await page.locator('#profile-toggle').click(); await page.locator('#language').selectOption('ru-RU'); await page.keyboard.press('Escape');
  await page.waitForFunction(() => document.querySelector('#elapsed').textContent !== '0:00');
  await page.locator('#player-play').click(); await page.locator('#player-play[aria-label="Воспроизвести"]').waitFor();
  const seek = page.locator('#player-seek');
  await seek.fill('500');
  await page.waitForFunction(() => {
    const input = document.querySelector('#player-seek');
    return Math.abs(Number(input.value) - 500) < 2;
  });
  await seek.evaluate(input => input.blur());
  await page.mouse.move(0, 0);
  await page.waitForTimeout(200);
  const seekThumb = await seek.evaluate(input => {
    const rect = input.getBoundingClientRect();
    const position = 4.5 + (rect.width - 9) * Number(input.value) / Number(input.max);
    return { x: Math.floor(rect.x + position - 7), y: Math.floor(rect.y - 7), width: 14, height: 18 };
  });
  const thumbHidden = await page.screenshot({ clip: seekThumb, animations: 'disabled' });
  await seek.hover();
  await page.waitForTimeout(200);
  const thumbHovered = await page.screenshot({ clip: seekThumb, animations: 'disabled' });
  assert.equal(thumbHidden.equals(thumbHovered), false, 'seek thumb becomes visible on hover');
  await page.mouse.move(0, 0);
  await page.waitForTimeout(200);
  assert.equal(thumbHidden.equals(await page.screenshot({ clip: seekThumb, animations: 'disabled' })), true, 'seek thumb disappears when the pointer leaves');
  await page.locator('#player-play').hover();
  assert.equal(await page.locator('#player-play').evaluate((button) => getComputedStyle(button).backgroundColor), 'rgb(248, 249, 255)', 'player button keeps its contrast on hover');
  await page.screenshot({ path: '../backend/.zig-cache/ui-desktop.png' });
  await page.locator('#queue-toggle').click();
  await page.waitForFunction(() => document.querySelector('#collection').getBoundingClientRect().right + 7 <= document.querySelector('#queue-panel').getBoundingClientRect().left);
  await overflow();
  assert.equal(await page.locator('#queue-panel').getAttribute('inert'), null);
  assert.equal(await page.locator('[data-queue-play]').count(), 2);
  await page.waitForFunction(() => document.querySelector('#queue-panel .queue-current img')?.naturalWidth > 0);
  await page.locator(`[data-queue-remove="${id(11)}"]`).click();
  assert.equal(await page.locator('[data-queue-play]').count(), 1);
  await page.locator(`[data-track-row="${id(11)}"]`).click({ button: 'right' });
  await page.getByRole('menuitem', { name: 'Добавить в очередь', exact: true }).click();
  assert.equal(await page.locator('[data-queue-play]').count(), 2);
  await page.screenshot({ path: '../backend/.zig-cache/ui-queue.png' });
  await page.locator(`[data-queue-play="${id(11)}"]`).click();
  await page.waitForFunction(() => document.querySelector('#now-title').textContent === 'Weightless');
  await page.locator('#player-play[aria-label="Пауза"]').waitFor();
  await page.locator('#queue-close').click();
  await page.locator(`[data-play="${id(10)}"]`).click(); await page.locator('#player-play[aria-label="Пауза"]').waitFor(); await page.locator('#player-play').click();
  await page.locator(`[data-track-menu="${id(10)}"]`).click();
  await page.locator(`[data-track-menu="${id(10)}"]`).click();
  assert.equal(await page.locator('#context-menu').isVisible(), false, 'second click on the same ellipsis closes the menu');
  await page.locator(`[data-track-menu="${id(10)}"]`).click();
  await page.locator('#attach-track').hover();
  assert.equal(await page.locator('#context-submenu').isVisible(), true, 'hover opens the adjacent submenu');
  assert.equal(await page.locator('#remove-track').isVisible(), true, 'parent actions remain visible');
  const parentMenu = await page.locator('#context-menu').boundingBox(); const childMenu = await page.locator('#context-submenu').boundingBox();
  assert.ok(childMenu.x + childMenu.width <= parentMenu.x || childMenu.x >= parentMenu.x + parentMenu.width, 'desktop submenu sits next to its parent');
  await page.locator('#attach-track').focus(); await page.keyboard.press('ArrowRight');
  assert.equal(await page.locator('#context-submenu').evaluate(el => el.contains(document.activeElement)), true);
  await page.keyboard.press('ArrowLeft');
  assert.equal(await page.locator('#context-submenu').isVisible(), false); assert.equal(await page.locator('#attach-track').evaluate(el => el === document.activeElement), true);
  await page.keyboard.press('ArrowRight'); await page.keyboard.press('Escape');
  assert.equal(await page.locator('#context-submenu').isVisible(), false); assert.equal(await page.locator('#context-menu').isVisible(), true);
  await page.locator('#attach-track').click(); await page.getByRole('menuitem', { name: 'В дороге', exact: true }).click();
  assert.equal(await page.locator('#context-menu').isVisible(), false); assert.equal(await page.locator('#context-submenu').isVisible(), false);
  await page.waitForFunction(() => document.querySelector('#toast').textContent === 'Трек добавлен в плейлист');
  assert.equal(members.get(id(4)).some(t => t.id === id(10)), true);

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
  assert.equal(await page.locator('.now-playing').isVisible(), false);
  await page.locator(`.sidebar [data-playlist="${id(4)}"]`).click();
  await page.getByRole('heading', { name: 'В дороге', exact: true }).waitFor();
  await page.locator('.topbar [data-action="upload"]').click();
  assert.equal(await page.locator('#upload-target').count(), 0);
  await page.locator('#file-input').setInputFiles([{ name: 'Artist - New song.mp3', mimeType: 'audio/mpeg', buffer: Buffer.from('mock audio') }, { name: 'Other.flac', mimeType: 'audio/flac', buffer: Buffer.from('mock flac') }]);
  assert.equal(await page.locator('[data-upload-title]').first().inputValue(), 'New song');
  await page.locator('[data-upload-artist]').first().fill('Edited artist');
  await page.screenshot({ path: '../backend/.zig-cache/ui-upload.png' });
  await page.locator('#start-upload').click(); await page.locator('.upload-item.done').nth(1).waitFor();
  assert.equal(mutations.filter((m) => m.path === '/api/tracks').length, 2);
  assert.equal(tracks.find((t) => t.title === 'New song').artist, 'Edited artist');
  assert.deepEqual(mutations.filter((m) => m.path === '/api/tracks').map((m) => m.body.playlist_ids), [[], []], 'files upload only to Uploads, even from another playlist');
  await page.locator('#upload-dialog [data-close]').click();
  await page.locator('.sidebar [data-action="new-playlist"]').click();
  await page.locator('#playlist-form [name="title"]').fill('Новый плейлист');
  await page.locator('#playlist-image-input').setInputFiles({ name: 'cover.png', mimeType: 'image/png', buffer: imageBytes });
  assert.equal(await page.locator('#playlist-image-preview').isVisible(), true);

  await page.locator('#playlist-save').click(); await page.locator('#playlist-dialog').waitFor({ state: 'hidden' }); await page.getByRole('heading', { name: 'Новый плейлист', exact: true }).waitFor();
  const created = playlists.find(p => p.title === 'Новый плейлист');
  assert.ok(created.image_key, 'artwork uploads after playlist creation');
  assert.ok(mutations.some(m => m.method === 'PUT' && m.path === `/api/playlists/${created.id}/image`));
  members.set(created.id, [tracks.find(track => track.id === id(11))]);
  assert.equal(new URL(page.url()).searchParams.get('playlist'), created.id);
  await page.reload(); await page.getByRole('heading', { name: created.title, exact: true }).waitFor();
  assert.equal(await page.locator('.sidebar [aria-current=page]').getAttribute('data-playlist'), created.id, 'reload restores the selected playlist instead of Uploads');
  await page.locator(`[data-play="${id(11)}"]`).click();
  await page.locator('#player-play[aria-label="Пауза"]').waitFor();
  const originalImageKey = created.image_key;
  await page.locator(`.sidebar [data-playlist="${created.id}"]`).click({ button: 'right' });
  await page.locator('#edit-playlist').click(); await page.locator('#playlist-dialog[open]').waitFor();
  await page.locator('#playlist-form [name=title]').fill('Updated mix');
  await page.locator('#playlist-form [name=description]').fill('New description');
  await page.locator('#playlist-form [name=visibility]').selectOption('public');
  await page.locator('#playlist-image-input').setInputFiles({ name: 'updated.png', mimeType: 'image/png', buffer: updatedImageBytes });
  await page.locator('#playlist-save').click(); await page.getByRole('heading', { name: 'Updated mix', exact: true }).waitFor();
  assert.notEqual(created.image_key, originalImageKey);
  const coverSelectors = ['.hero-cover img', `.sidebar [data-playlist="${created.id}"] img`];
  for (const selector of coverSelectors) {
    await page.waitForFunction(selector => {
      const image = document.querySelector(selector);
      return image?.complete && image.naturalWidth === 16;
    }, selector);
    const cover = page.locator(selector);
    assert.equal(new URL(await cover.getAttribute('src'), base).searchParams.get('v'), created.image_key, 'cover URL follows its new storage key without a page reload');
    const pixel = await cover.evaluate(image => {
      const canvas = document.createElement('canvas'); canvas.width = canvas.height = 1;
      const context = canvas.getContext('2d'); context.drawImage(image, 0, 0, 1, 1);
      return [...context.getImageData(0, 0, 1, 1).data];
    });
    assert.ok(pixel[2] > 200 && pixel[0] < 20, 'replacement artwork is rendered in the playlist and sidebar');
  }
  assert.equal(created.description, 'New description'); assert.equal(created.visibility, 'public'); assert.deepEqual(created.tags, ['ambient']);
  await page.locator(`.sidebar [data-playlist="${created.id}"]`).click({ button: 'right' });
  await page.locator('#delete-playlist').click();
  assert.match(await page.locator('#confirm-description').textContent(), /Треки останутся/);
  await page.locator('#confirm-delete').click(); await page.getByRole('heading', { name: 'Uploads', exact: true }).waitFor();
  assert.equal(playlists.some(p => p.id === created.id), false);
  await page.locator('.sidebar [data-action=new-playlist]').click();
  await page.locator('#playlist-form [name=title]').fill('Retry cover');
  await page.locator('#playlist-image-input').setInputFiles({ name: 'cover.png', mimeType: 'image/png', buffer: imageBytes });
  failImage = true; const beforeCreates = mutations.filter(m => m.method === 'POST' && m.path === '/api/playlists').length;
  await page.locator('#playlist-save').click();
  await page.getByText('Плейлист сохранён, но обложка не загружена.', { exact: false }).waitFor();
  await page.locator('#playlist-save').click(); await page.locator('#playlist-dialog').waitFor({ state: 'hidden' });
  assert.equal(mutations.filter(m => m.method === 'POST' && m.path === '/api/playlists').length, beforeCreates + 1, 'retry artwork without creating a duplicate playlist');

  await openSpotify();
  await page.locator('#spotify-files').setInputFiles([{ name: 'Broken.json', mimeType: 'application/json', buffer: Buffer.from('{broken') }]);
  await page.getByText('Broken.json: некорректный JSON', { exact: true }).waitFor();
  assert.equal(await page.locator('#spotify-start').isDisabled(), true);
  const uri = 'spotify:track:0123456789012345678901';
  await page.locator('#spotify-files').setInputFiles([
    { name: 'Playlists.json', mimeType: 'application/json', buffer: Buffer.from(JSON.stringify({ playlists: [{ name: 'Spotify mix', items: [{ track: { trackName: 'Get Lucky', artistName: 'Daft Punk', trackUri: uri } }] }] })) },
    { name: 'YourLibrary.json', mimeType: 'application/json', buffer: Buffer.from(JSON.stringify({ tracks: [{ track: 'Get Lucky', artist: 'Daft Punk', uri }] })) },
  ]);
  await page.getByText('1 уникальных треков · 1 плейлистов', { exact: true }).waitFor();
  await page.locator('#spotify-start').click();
  await page.waitForFunction(() => document.querySelector('#spotify-progress').textContent.length > 0);
  assert.equal(await page.locator('#spotify-retry').count(), 0);
  assert.equal(await page.locator('#spotify-start').isDisabled(), true);
  assert.equal(mutations.filter((m) => m.path === '/api/spotify/import').length, 1);
  await page.locator('#spotify-dialog [data-close]').click();
  const selectedBeforeReload = await page.locator('h1').textContent();
  await page.reload(); await page.getByRole('heading', { name: selectedBeforeReload, exact: true }).waitFor();
  await openSpotify();
  assert.equal(await page.locator('#spotify-progress').textContent(), '');
  assert.equal(mutations.some((m) => m.path.startsWith('/api/spotify/imports/')), false);
  await page.locator('#spotify-dialog [data-close]').click();
  for (const viewport of [{ width: 390, height: 844 }, { width: 320, height: 568 }]) {
    await page.setViewportSize(viewport); await overflow();
    assert.equal(await page.locator('.topbar [data-action="upload"]').isVisible(), false);
    await page.locator('#open-library').click(); await page.locator(`#library-dialog [data-playlist="${id(2)}"]`).click();
    await page.getByRole('heading', { name: 'Uploads', exact: true }).waitFor();
    assert.equal(await page.locator('#library-dialog').isVisible(), false);
    await page.locator('[data-track-menu]').first().click();
    await page.locator('#attach-track').click();
    assert.equal(await page.locator('#context-menu').isVisible(), true); assert.equal(await page.locator('#context-submenu').isVisible(), true);
    const mobileRoot = await page.locator('#context-menu').boundingBox(); const mobileChild = await page.locator('#context-submenu').boundingBox();
    assert.ok(mobileChild.y >= mobileRoot.y + mobileRoot.height, 'narrow screens keep submenu below parent');
    assert.ok(mobileChild.x >= 0 && mobileChild.x + mobileChild.width <= viewport.width && mobileChild.y + mobileChild.height <= viewport.height, 'submenu stays in the viewport');
    await page.keyboard.press('Escape'); await page.keyboard.press('Escape');
    await page.screenshot({ path: `../backend/.zig-cache/ui-mobile-${viewport.width}.png` });
    await page.locator('#queue-toggle').click(); await page.locator('#queue-panel.open').waitFor(); await overflow();
    await page.waitForFunction(() => document.querySelector('#collection').getBoundingClientRect().bottom + 5 <= document.querySelector('#queue-panel').getBoundingClientRect().top);
    await page.locator('#queue-close').click();
    await page.locator('#open-library').click(); await page.locator(`#library-dialog [data-playlist="${id(2)}"]`).click({ button: 'right' });
    assert.equal(await page.locator('#delete-playlist').isDisabled(), true);
    assert.equal(await page.locator('#context-menu').isVisible(), true);
    await page.keyboard.press('Escape'); await page.locator('#library-dialog [data-close]').click();
    await toggleTheme(); await overflow();
    await page.screenshot({ path: `../backend/.zig-cache/ui-light-mobile-${viewport.width}.png` });
    await toggleTheme();
    await openSpotify();
    await page.locator('#spotify-dialog[open]').waitFor(); await overflow();
    assert.equal(await page.locator('#library-dialog').isVisible(), false);
    await page.screenshot({ path: `../backend/.zig-cache/ui-spotify-${viewport.width}.png` });
    await page.locator('#spotify-dialog [data-close]').click();
  }
  expireLibrary = true;
  await page.locator('#auth-dialog[open]').waitFor({ timeout: 15000 });
  assert.equal(await page.locator('#toast').isVisible(), false, 'an expired-session notice is hidden behind mandatory login');
  expireLibrary = false;
  authenticated = false; await page.reload(); await page.locator('#auth-dialog[open]').waitFor(); await overflow();
  assert.equal(await page.locator('#toast').isVisible(), false, 'the initial anonymous 401 does not display an error behind login');
  assert.equal(await page.locator('#toast').textContent(), '', 'the initial anonymous 401 is an expected signed-out state');
  assert.equal(await page.locator('.auth-placeholder').isVisible(), true, 'login renders a neutral placeholder behind the blur');
  assert.equal(await page.locator('.auth-placeholder').getAttribute('inert'), '');
  assert.equal(await page.locator('.track-row').count(), 0, 'placeholder does not render library metadata');
  assert.match(await page.locator('#auth-dialog').evaluate(dialog => getComputedStyle(dialog, '::backdrop').backdropFilter), /blur/);
  await page.setViewportSize({ width: 1440, height: 900 });
  await overflow();
  await page.screenshot({ path: '../backend/.zig-cache/ui-auth-placeholder-desktop.png' });
  await page.setViewportSize({ width: 390, height: 844 });
  await overflow();
  await page.screenshot({ path: '../backend/.zig-cache/ui-auth-placeholder-mobile.png' });
  assert.equal(await page.locator('#auth-dialog [data-close]').count(), 0, 'unauthenticated login has no close button');
  await page.keyboard.press('Escape');
  assert.equal(await page.locator('#auth-dialog').isVisible(), true, 'Escape cannot dismiss mandatory login');
  await page.mouse.click(1, 1);
  assert.equal(await page.locator('#auth-dialog').isVisible(), true, 'backdrop cannot dismiss mandatory login');
  await page.locator('#auth-form [name="username"]').fill('music_lover');
  await page.locator('#auth-form [name="password"]').fill('wrong-password-123');
  await page.locator('#auth-submit').click();
  await page.waitForFunction(() => document.querySelector('#auth-error').textContent.length > 0);
  assert.equal(await page.locator('#auth-error').isVisible(), true, 'login errors remain visible inside the form');
  assert.equal(await page.locator('#toast').isVisible(), false);
  await page.locator('#auth-form [name="password"]').fill('test-password-123');
  const firstTrack = tracks.find(track => track.title === 'New song');
  assert.equal(firstTrack.status, 'streamed');
  firstTrack.status = 'ready';
  await page.locator('#auth-submit').click(); await page.getByRole('heading', { name: 'Uploads', exact: true }).waitFor();
  verifyPlaybackCookie = true;
  // Exercise preparation as well as HLS requests on the first play after login.
  await page.locator(`[data-play="${firstTrack.id}"]`).click();
  await page.waitForFunction(() => document.querySelector('#player-play')?.getAttribute('aria-label') === 'Пауза');
  await page.waitForFunction(() => Number(document.querySelector('#player-seek').value) > 0);
  assert.ok(playbackCookies.some(request => request.path.endsWith('/hls')));
  assert.ok(playbackCookies.some(request => request.path.endsWith('.ts')));
  assert.ok(playbackCookies.every(request => request.cookie.includes(`musica_session=${'b'.repeat(64)}`)), 'preparation, manifest and segments use the new login cookie');
  assert.equal(await page.locator('#auth-dialog').isVisible(), false);
  assert.doesNotMatch(await page.locator('#toast').textContent(), /войти|Войдите/);
  await page.locator('#profile-toggle').click();
  assert.equal(authenticated, true, 'profile click opens the menu without signing out');
  await page.locator('#profile-menu [data-action="logout"]').click();
  await page.locator('#auth-dialog[open]').waitFor();
  assert.equal(authenticated, false, 'sign out is available in the profile menu');
  assert.deepEqual(errors, []);
  console.log('PASS: rounded responsive panels, context menus, playlist editing/deletion/artwork/retry, queue playback/removal, mute, duration placeholders, localization, HLS, uploads, Spotify and auth.');
} finally { await browser.close(); rmSync(temporary, { recursive: true, force: true }); }
