import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { chromium } from 'playwright';

const base = process.env.UI_TEST_URL || 'http://127.0.0.1:5173';
const edge = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM_PATH || (existsSync(edge) ? edge : undefined),
  headless: true,
});
const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, serviceWorkers: 'block' });
const page = await context.newPage();
const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const user = { id: id(1), username: 'web_listener', default_playlist_id: id(2) };
const playlist = {
  id: id(2), owner_id: user.id, title: 'Uploads', description: '', tags: [],
  visibility: 'private', is_default: true, image_key: null, role: 'owner', track_count: 0,
};
const song = {
  external_id: '123', title: '<img src=x> (Live Remix)', artist: 'Artist',
  album: 'Album', duration_seconds: 123, artwork_url: 'https://example.com/cover.jpg', store_url: null,
};
const tracks = [];
const searches = [];
let additions = 0;
let failLibrary = false;
let releaseOld;
let oldArrived;
const errors = [];
page.on('pageerror', error => errors.push(error.message));
await page.route('https://example.com/cover.jpg', route => route.fulfill({
  contentType: 'image/svg+xml',
  body: '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect width="100" height="100" fill="#286ad4"/><circle cx="50" cy="50" r="24" fill="#72e0f0"/></svg>',
}));
await page.route('**/api/**', async route => {
  const request = route.request();
  const url = new URL(request.url());
  if (!url.pathname.startsWith('/api/')) return route.continue();
  const json = (data, status = 200) => route.fulfill({
    status, contentType: 'application/json', body: JSON.stringify(data),
  });
  if (url.pathname === '/api/users/me') return json(user);
  if (url.pathname === '/api/playlists') return json([{ ...playlist, track_count: tracks.length }, { ...playlist, id: id(4), title: 'Other playlist', is_default: false, track_count: 1 }]);
  if (url.pathname === `/api/playlists/${id(4)}`) {
    if (failLibrary) return json({ error: 'internal_error' }, 500);
    return json({ ...playlist, id: id(4), is_default: false, tracks: [{ id: id(5), title: 'Local favorite', artist: 'Local artist', owner_id: user.id, status: 'streamed' }, ...tracks] });
  }
  if (url.pathname === `/api/playlists/${id(2)}`) return json({ ...playlist, tracks });
  if (url.pathname === '/api/web/search') {
    const query = url.searchParams.get('q');
    searches.push(query);
    if (query === 'failure') return json({ error: 'web_search_unavailable' }, 503);
    if (query === 'old query') {
      oldArrived();
      await new Promise(resolve => { releaseOld = resolve; });
      return json({ tracks: [{ ...song, external_id: '124', title: 'Old result' }] }).catch(() => {});
    }
    return json({ tracks: query === 'empty' ? [] : [song] });
  }
  if (url.pathname === '/api/web/tracks') {
    assert.deepEqual(request.postDataJSON(), { external_id: '123' });
    additions++;
    tracks.push({ id: id(3), owner_id: id(9), shared: true, title: song.title, artist: song.artist, status: 'pending' });
    return json({ id: id(3) }, 202);
  }
  return json({ error: 'not_found' }, 404);
});

try {
  await page.goto(base);
  await page.getByRole('heading', { name: 'Uploads', exact: true }).waitFor({ timeout: 10000 }).catch(async error => {
    console.error('Startup UI:', await page.locator('body').innerText(), errors);
    throw error;
  });
  await page.locator('#search').focus();
  await page.locator('#search').fill('Artist & Song');
  assert.equal(searches.length, 0, 'typing alone does not query the provider');
  await page.locator('#search').press('Enter');
  await page.locator('.search-result[data-source=web]').waitFor();
  assert.deepEqual(searches, ['Artist & Song']);
  assert.equal(await page.locator('.search-result-text strong').textContent(), song.title);
  assert.equal(await page.locator('.search-result-text img').count(), 0, 'metadata is rendered as text');
  assert.equal(await page.locator('.search-result-duration').textContent(), '2:03');
  assert.equal(await page.locator('.search-result-art img').getAttribute('src'), song.artwork_url);
  await page.screenshot({ path: '../backend/.zig-cache/search-dropdown-desktop.png' });
  const add = page.locator('.search-result-action');
  await add.click();
  await page.getByRole('button', { name: 'Добавить «<img src=x> (Live Remix)» в Uploads' }).filter({ hasText: 'Добавлено' }).waitFor();
  assert.equal(await add.isDisabled(), true);
  assert.equal(additions, 1);
  assert.equal(await page.locator('#search-results').isVisible(), true, 'library refresh preserves the dropdown');
  assert.equal(await page.getByRole('heading', { name: 'Uploads', exact: true }).isVisible(), true, 'search does not replace the playlist');
  await page.locator('#search').press('Escape');
  await page.locator('#search-results').waitFor({ state: 'detached' });
  await page.locator('.track-row').waitFor();
  assert.match(await page.locator('.track-row').textContent(), /Live Remix/);

  const previousSearches = searches.length;
  await page.locator('#search').fill('local favorite');
  await page.locator('#search').press('Enter');
  await page.locator('.search-result[data-source=local]').waitFor();
  assert.equal(await page.locator('.search-result-text strong').textContent(), 'Local favorite');
  assert.equal(searches.length, previousSearches, 'a match in another playlist suppresses the catalog lookup');
  await page.locator('#search').fill('Live Remix');
  await page.locator('#search').press('Enter');
  await page.locator('.search-result[data-source=local]').waitFor();
  assert.equal(await page.locator('.search-result-action').isDisabled(), true, 'pending tracks are found but cannot be played yet');
  assert.equal(await page.locator('.search-result').count(), 1, 'a track present in two playlists is deduplicated');
  assert.equal(searches.length, previousSearches);
  failLibrary = true;
  await page.locator('#search').fill('library read error');
  await page.locator('#search').press('Enter');
  await page.locator('#search-results [role=alert]').waitFor();
  assert.equal(searches.length, previousSearches, 'a failed local lookup must not fall through to the provider');
  failLibrary = false;
  await page.locator('#search').fill('failure');
  await page.locator('#search').press('Enter');
  await page.getByRole('alert').filter({ hasText: 'Каталог временно недоступен' }).waitFor();
  await page.locator('#search').fill('empty');
  await page.locator('#search').press('Enter');
  await page.getByText('Ничего не найдено. Попробуйте другое название или исполнителя.').waitFor();

  const old = new Promise(resolve => { oldArrived = resolve; });
  await page.locator('#search').fill('old query');
  await page.locator('#search').press('Enter');
  await old;
  await page.locator('#search').fill('new query');
  await page.locator('#search').press('Enter');
  await page.locator('.search-result[data-source=web]').waitFor();
  releaseOld();
  await page.waitForTimeout(150);
  assert.equal(await page.getByText('Old result', { exact: true }).count(), 0, 'stale search cannot replace newer results');
  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  await page.screenshot({ path: '../backend/.zig-cache/search-dropdown-mobile.png' });
  await page.locator('#profile-toggle').click();
  await page.locator('#language').selectOption('en-US');
  await page.locator('#search').fill('');
  await page.getByRole('heading', { name: 'Recent finds' }).waitFor();
  assert.equal(await page.locator('.search-result').count(), 1, 'selected results are remembered for this session');
  await page.locator('#search').press('Escape');
  await page.locator('#search-results').waitFor({ state: 'detached' });
  await page.locator('#search').fill('local favorite');
  await page.locator('.search-result[data-source=local]').waitFor();
  assert.equal(await page.locator('.search-result-text strong').textContent(), 'Local favorite', 'typing searches automatically after the debounce');
  await page.locator('#profile-toggle').click();
  await page.locator('#search-results').waitFor({ state: 'detached' });
  await page.keyboard.press('Escape');
  assert.deepEqual(errors, []);
  console.log('PASS: unified dropdown search, full-library priority, pending tracks, safe metadata, ID-only addition, unchanged playlist, recents, cancellation, errors, mobile layout and localization.');
} finally {
  releaseOld?.();
  await browser.close();
}
