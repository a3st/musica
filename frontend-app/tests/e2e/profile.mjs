import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { chromium } from 'playwright';

const player = process.env.UI_TEST_URL || 'http://127.0.0.1:5173/';
const profile = process.env.PROFILE_TEST_URL || 'http://127.0.0.1:5174/profile/';
const edge = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const browser = await chromium.launch({ headless: true,
  executablePath: process.env.CHROMIUM_PATH || (existsSync(edge) ? edge : undefined) });
let signedIn = false;
let registration = false;
let cleaned = false;
const user = { id: '11111111-1111-4111-8111-111111111111', username: 'fixture_admin', role: 'admin',
  default_playlist_id: '22222222-2222-4222-8222-222222222222' };
const errors = [];

try {
  const context = await browser.newContext();
  await context.route('**/api/**', async route => {
    const path = new URL(route.request().url()).pathname;
    if (!path.startsWith('/api/')) return route.continue();
    const json = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
    if (path === '/api/users/me') return signedIn ? json(user) : json({ error: 'unauthorized' }, 401);
    if (path === '/api/capabilities') return json({ web_search: false, spotify_import: false, registration_enabled: registration });
    if (path === '/api/auth/logout') { signedIn = false; return route.fulfill({ status: 204 }); }
    if (path === '/api/admin/users') return json([
      { ...user, created_at: '2026-10-12T00:00:00Z', tracks: 3 },
      { id: '33333333-3333-4333-8333-333333333333', username: 'another_user', role: 'user', created_at: '2026-10-12T00:00:00Z', tracks: 2 },
    ]);
    if (path === '/api/admin/storage') return json({ source_bytes: 1000, user_bytes: 600, system_bytes: 400,
      orphaned_bytes: cleaned ? 0 : 200, tracks: 40, orphaned_tracks: cleaned ? 0 : 23,
      pending_tracks: 2, hls_segments: 100, cleanup_jobs: 0 });
    if (path === '/api/admin/storage/cleanup-orphaned') { cleaned = true; return json({ removed: 23, skipped: 0 }); }
    if (path === '/api/playlists') return json([]);
    if (path === `/api/playlists/${user.default_playlist_id}`) return json({
      id: user.default_playlist_id, owner_id: user.id, title: 'Uploads', description: '',
      visibility: 'private', is_default: true, image_key: null, tracks: [],
    });
    throw new Error(`Unexpected fixture request: ${path}`);
  });
  const page = await context.newPage();
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(profile);
  await page.locator('#auth-form').waitFor();
  assert.equal(await page.locator('#auth-switch').count(), 0, 'disabled registration is hidden');
  registration = true;
  await page.reload();
  await page.locator('#auth-switch').waitFor();

  signedIn = true;
  await page.reload();
  await page.getByRole('heading', { name: 'Профиль', exact: true }).waitFor();
  assert.equal(await page.locator('.profile-actions').innerText(), 'F', 'only the avatar initial remains');
  assert.match(await page.locator('.settings-row').first().innerText(), /Имя аккаунта\s+fixture_admin/);
  assert.equal(await page.locator('.account-role').count(), 0);
  await page.locator('#profile-toggle').click();
  assert.equal(await page.locator('#profile-menu button').count(), 1);
  await page.locator('#profile-toggle').click();
  assert.equal(await page.locator('#profile-menu').count(), 0);
  const sidebar = await page.locator('.sidebar').boundingBox();
  assert.ok(sidebar.height < 260, 'desktop sidebar wraps its buttons');

  await page.getByRole('button', { name: 'Пользователи', exact: true }).click();
  await page.getByText('another_user', { exact: true }).waitFor();
  assert.equal(new URL(page.url()).searchParams.get('page'), 'users');
  await page.reload();
  await page.getByRole('heading', { name: 'Пользователи', exact: true }).waitFor();
  const row = page.locator('tbody tr').filter({ hasText: 'another_user' });
  await page.locator('h1').hover();
  assert.equal(await row.locator('.delete-user').evaluate(element => getComputedStyle(element).opacity), '0');
  await row.hover();
  await page.waitForFunction(() => getComputedStyle(document.querySelector('tbody tr:last-child .delete-user')).opacity === '1');

  await page.getByRole('button', { name: 'Хранилище', exact: true }).click();
  await page.locator('.donut').waitFor();
  assert.equal(await page.locator('.legend').count(), 3);
  assert.equal(await page.locator('.orphan-bar').count(), 0);
  assert.equal(await page.getByRole('button', { name: 'Обновить', exact: true }).count(), 0);
  const cleanup = page.getByRole('button', { name: 'Удалить orphaned-треки', exact: true });
  await cleanup.click();
  assert.doesNotMatch(await page.locator('#cleanup-dialog').innerText(), /20/);
  await page.locator('#cleanup-dialog .danger').click();
  await page.getByText('Удалено: 23. Пропущено: 0.', { exact: true }).waitFor();
  await page.reload();
  await page.locator('.donut').waitFor();
  assert.equal(new URL(page.url()).searchParams.get('page'), 'storage');
  await page.goBack();
  await page.getByRole('heading', { name: 'Пользователи', exact: true }).waitFor();
  await page.goForward();
  await page.getByRole('heading', { name: 'Хранилище', exact: true }).waitFor();
  await page.setViewportSize({ width: 390, height: 844 });
  const mobileSidebar = await page.locator('.sidebar').boundingBox();
  assert.ok(mobileSidebar.height < 100, `mobile navigation has no stretched empty row: ${JSON.stringify(mobileSidebar)}`);
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));

  await page.getByRole('button', { name: 'Профиль', exact: true }).click();
  await page.locator('#language-toggle').click();
  await page.getByRole('option', { name: 'English (US)', exact: true }).click();
  await page.waitForFunction(() => document.title === 'Musica · Profile');
  const playerPage = await context.newPage();
  playerPage.on('pageerror', error => errors.push(error.message));
  await playerPage.goto(player);
  await playerPage.waitForFunction(() => document.title === 'Musica · Player');
  await playerPage.evaluate(() => {
    document.cookie = 'musica_locale=ru-RU; Path=/; SameSite=Lax';
    localStorage.setItem('musica:locale', 'ru-RU');
    window.dispatchEvent(new Event('focus'));
  });
  await playerPage.waitForFunction(() => document.title === 'Musica · Плеер');
  await page.bringToFront();
  await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  await page.waitForFunction(() => document.title === 'Musica · Профиль');
  const icon = await page.locator('link[rel="icon"]').getAttribute('href');
  assert.deepEqual(await (await context.request.get(new URL(icon, page.url()).href)).body(),
    await (await context.request.get(new URL('/icon.svg', player).href)).body());
  await page.locator('#profile-toggle').click();
  await page.locator('#profile-menu button').click();
  await page.locator('#auth-form').waitFor();
  assert.deepEqual(errors, []);
  console.log('PASS: compact profile menus, hover actions, orphan chart/cleanup, registration capability, persistent routes, mobile spacing, shared locales and favicon.');
} finally {
  await browser.close();
}
