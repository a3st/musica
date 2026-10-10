import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { chromium } from 'playwright';

const base = process.env.UI_TEST_URL || 'http://127.0.0.1:5173';
const temporary = mkdtempSync(join(tmpdir(), 'musica-web-ui-'));
const media = spawnSync(process.env.FFMPEG_PATH || 'ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=13',
  '-c:a', 'aac', '-f', 'hls', '-hls_time', '6', '-hls_playlist_type', 'vod', '-hls_segment_filename',
  join(temporary, 'segment-%06d.ts'), join(temporary, 'index.m3u8')]);
assert.equal(media.status, 0, `FFmpeg required for Web playback checks: ${media.error || media.stderr}`);
const edge = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM_PATH || (existsSync(edge) ? edge : undefined),
  headless: true,
});
const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, serviceWorkers: 'block' });
const page = await context.newPage();
await page.addInitScript(() => {
  window.copiedSource = null;
  Object.defineProperty(navigator, 'clipboard', { value: { writeText: async value => { window.copiedSource = value; } } });
});
const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const user = { id: id(1), username: 'web_listener', default_playlist_id: id(2) };
const playlist = {
  id: id(2), owner_id: user.id, title: 'Uploads', description: '', tags: [],
  visibility: 'private', is_default: true, image_key: null, role: 'owner', track_count: 0,
};
const song = {
  provider: 'itunes', external_id: '123', title: '<img src=x> (Live Remix)', artist: 'Artist',
  album: 'Album', artwork_url: 'https://example.com/cover.jpg', source_url: 'https://music.apple.com/us/song/123',
};
const tracks = [];
const searches = [];
let additions = 0;
const attachments = [];
let simulateDownload = false;
let downloadReads = 0;
let preparationReads = 0;
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
  if (url.pathname === `/api/playlists/${id(2)}`) {
    if (simulateDownload && ++downloadReads >= 2) tracks[0].status = 'ready';
    return json({ ...playlist, tracks });
  }
  if (url.pathname === '/api/web/search') {
    const query = url.searchParams.get('q');
    searches.push(query);
    if (query === 'failure') return json({ error: 'web_search_unavailable' }, 503);
    if (query === 'old query') {
      oldArrived();
      await new Promise(resolve => { releaseOld = resolve; });
      return json({ tracks: [{ ...song, external_id: '124', title: 'Old result' }] }).catch(() => {});
    }
    return json({ tracks: query === 'empty' ? [] : query === 'many results'
      ? Array.from({ length: 20 }, (_, index) => ({ ...song, external_id: String(1000 + index), title: `Catalog track ${index}` }))
      : [song] });
  }
  if (url.pathname === '/api/web/tracks') {
    assert.deepEqual(request.postDataJSON(), { provider: 'itunes', external_id: '123' });
    additions++;
    tracks.push({ id: id(3), owner_id: id(9), shared: true, title: song.title, artist: song.artist, status: 'pending' });
    return json({ id: id(3) }, 202);
  }
  if (url.pathname === `/api/playlists/${id(4)}/tracks/${id(3)}` && request.method() === 'PUT') {
    attachments.push({ playlist: id(4), track: id(3) });
    return route.fulfill({ status: 204 });
  }
  if (url.pathname === `/api/tracks/${id(3)}/hls/status`) {
    preparationReads++;
    return json(preparationReads === 1 ? { status: 'ready', preparation: null } : { status: 'streamed', preparation: 'completed' });
  }
  if (url.pathname === `/api/tracks/${id(3)}/hls/index.m3u8`)
    return route.fulfill({ contentType: 'application/vnd.apple.mpegurl', body: readFileSync(join(temporary, 'index.m3u8')) });
  if (/\/hls\/segment-\d{6}\.ts$/.test(url.pathname))
    return route.fulfill({ contentType: 'video/mp2t', body: readFileSync(join(temporary, url.pathname.split('/').at(-1))) });
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
  assert.equal(await page.locator('.search-result-duration').count(), 0);
  assert.equal(await page.locator('.search-result-art img').getAttribute('src'), song.artwork_url);
  await page.screenshot({ path: '../backend/.zig-cache/search-dropdown-desktop.png' });
  await page.mouse.move(1, 850);
  assert.equal(await page.locator('.search-result-more').evaluate(element => getComputedStyle(element).opacity), '0');
  await page.locator('.search-result').hover();
  const add = page.locator('.search-result-add');
  await add.click();
  await page.getByRole('button', { name: 'Добавлено', exact: true }).waitFor();
  assert.equal(await add.isDisabled(), true);
  assert.equal(additions, 1);
  await page.locator('.search-result-more').click();
  await page.locator('#context-menu').getByRole('menuitem').last().click();
  assert.equal(await page.evaluate(() => window.copiedSource), song.source_url);
  assert.equal(await page.locator('#search-results').isVisible(), true);
  await page.locator('.search-result-more').click();
  await page.getByRole('menuitem', { name: 'Добавить в другой плейлист', exact: true }).hover();
  await page.getByRole('menuitem', { name: 'Other playlist', exact: true }).click();
  await page.waitForFunction(() => document.querySelector('.toast')?.textContent?.includes('Трек добавлен'));
  assert.deepEqual(attachments, [{ playlist: id(4), track: id(3) }]);
  assert.equal(additions, 1, 'adding to another playlist reuses the imported track');
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
  await page.locator('#search').fill('play catalog');
  await page.locator('#search').press('Enter');
  await page.locator('.search-result[data-source=web]').waitFor();
  simulateDownload = true;
  await page.locator('.search-result-art').click();
  await page.locator('.search-result-art[aria-busy="true"]').waitFor();
  await page.locator('#player-play[aria-label="Пауза"]').waitFor();
  assert.equal(await page.locator('#now-title').textContent(), song.title);
  assert.ok(downloadReads >= 2 && preparationReads >= 2, 'play waits for the source download and automatic HLS preparation');
  assert.equal(additions, 1, 'playing an added catalog result reuses its ID');
  simulateDownload = false;
  await page.locator('#player-play').click();
  const afterPlaybackSearches = searches.length;
  failLibrary = true;
  await page.locator('#search').fill('library read error');
  await page.locator('#search').press('Enter');
  await page.locator('#search-results [role=alert]').waitFor();
  assert.equal(searches.length, afterPlaybackSearches, 'a failed local lookup must not fall through to the provider');
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
  await page.locator('#search').fill('many results');
  await page.locator('#search').press('Enter');
  await page.waitForFunction(() => document.querySelectorAll('.search-result').length === 20);
  const searchRail = page.locator('.search-container .collection-scrollbar');
  await searchRail.waitFor();
  const railBox = await searchRail.boundingBox();
  const dropdownBox = await page.locator('#search-results').boundingBox();
  assert.equal(railBox.width, 8);
  assert.ok(Math.abs(railBox.x + railBox.width - dropdownBox.x - dropdownBox.width) < 1, 'search scrollbar is flush with the panel edge');
  assert.equal(await page.locator('#search-results').evaluate(element => getComputedStyle(element).scrollbarWidth), 'none', 'native scrollbar arrows are hidden');
  await page.screenshot({ path: '../backend/.zig-cache/search-dropdown-actions.png' });
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
  console.log('PASS: unified dropdown search, full-library priority, pending tracks, safe metadata, provider/ID addition and source-link copying, unchanged playlist, recents, cancellation, errors, mobile layout and localization.');
} finally {
  releaseOld?.();
  await browser.close();
  rmSync(temporary, { recursive: true, force: true });
}
