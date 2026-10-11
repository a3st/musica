import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { chromium } from 'playwright';

const player = process.env.UI_TEST_URL || 'http://127.0.0.1:5173/';
const profile = process.env.PROFILE_TEST_URL || 'http://127.0.0.1:5174/profile/';
const edge = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const browser = await chromium.launch({ headless: true,
  executablePath: process.env.CHROMIUM_PATH || (existsSync(edge) ? edge : undefined) });
const id = '11111111-1111-4111-8111-111111111111';
const playlistId = '22222222-2222-4222-8222-222222222222';
const user = { id, username: 'music_lover', role: 'user', default_playlist_id: playlistId };
const playlist = { id: playlistId, owner_id: id, title: 'Uploads', description: '',
  visibility: 'private', role: 'owner', is_default: true, image_key: null, tags: [], track_count: 0,
  duration_seconds: 0, duration_complete: true, cover_tracks: [], tracks: [] };
const errors = [];

try {
  const context = await browser.newContext();
  await context.route('**/api/**', async route => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    if (!path.startsWith('/api/')) return route.continue();
    const reply = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
    if (path === '/api/users/me') return request.headers().cookie?.includes('musica_session=')
      ? reply(user) : reply({ error: 'unauthorized' }, 401);
    if (path === '/api/auth/login' || path === '/api/auth/register') {
      assert.equal(request.postDataJSON().username, user.username);
      if (request.postDataJSON().password === 'wrong-password-123') return reply({ error: 'unauthorized' }, 401);
      return route.fulfill({ status: path.endsWith('register') ? 201 : 200,
        contentType: 'application/json', headers: { 'Set-Cookie': `musica_session=${'b'.repeat(64)}; Path=/api; HttpOnly; SameSite=Strict` },
        body: JSON.stringify({ user_id: id }) });
    }
    if (path === '/api/capabilities') return reply({ web_search: false, spotify_import: false, registration_enabled: true });
    if (path === '/api/playlists') return reply([playlist]);
    if (path === `/api/playlists/${playlistId}`) return request.headers().cookie?.includes('musica_session=')
      ? reply(playlist) : reply({ error: 'unauthorized' }, 401);
    throw new Error(`Unexpected fixture request: ${path}`);
  });
  const page = await context.newPage();
  page.on('pageerror', error => errors.push(error.message));

  for (const register of [false, true]) {
    await context.clearCookies();
    const destination = new URL(player);
    destination.searchParams.set('playlist', playlistId);
    await page.goto(destination.href);
    await page.locator('#auth-dialog[open]').waitFor();
    assert.equal(await page.locator('#auth-form').count(), 0);
    await page.locator('#auth-submit').click();
    await page.locator('#auth-form').waitFor();
    assert.equal(await page.title(), 'Musica · Профиль');
    assert.equal(new URL(page.url()).origin, new URL(profile).origin);
    if (register) await page.locator('#auth-switch').click();
    await page.locator('[name="username"]').fill(user.username);
    await page.locator('[name="password"]').fill('wrong-password-123');
    await page.locator('#auth-submit').click();
    await page.waitForFunction(() => document.querySelector('#auth-error').textContent.length > 0);
    assert.equal(new URL(page.url()).pathname, '/profile/');
    await page.locator('[name="password"]').fill('test-password-123');
    const response = page.waitForResponse(r => r.url().endsWith(register ? '/auth/register' : '/auth/login') && r.status() < 300);
    await page.locator('#auth-submit').click();
    await response;
    await page.waitForURL(url => url.origin === destination.origin && url.searchParams.get('playlist') === playlistId);
    await page.getByRole('heading', { name: 'Uploads', exact: true }).waitFor();
    assert.equal(await page.locator('#auth-dialog').isVisible(), false);
    const cookie = (await context.cookies()).find(value => value.name === 'musica_session');
    assert.equal(cookie.httpOnly, true);
    assert.equal(cookie.path, '/api');
  }

  await page.goto(profile);
  await page.getByRole('heading', { name: 'Профиль', exact: true }).waitFor();
  assert.equal(await page.title(), 'Musica · Профиль');
  const unsafe = new URL(profile);
  unsafe.searchParams.set('return_to', 'https://evil.example/');
  await page.goto(unsafe.href);
  await page.getByRole('heading', { name: 'Профиль', exact: true }).waitFor();
  assert.equal(new URL(page.url()).origin, new URL(profile).origin);

  const returning = new URL(profile);
  returning.searchParams.set('return_to', new URL(`?playlist=${playlistId}`, player).href);
  await page.goto(returning.href);
  await page.waitForURL(url => url.origin === new URL(player).origin);
  await page.getByRole('heading', { name: 'Uploads', exact: true }).waitFor();
  assert.deepEqual(errors, []);
  console.log('PASS: centralized login/registration, HttpOnly cookie across dev ports, playlist return, direct profile and unsafe redirect rejection.');
} finally {
  await browser.close();
}
