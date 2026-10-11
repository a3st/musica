import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { chromium } from 'playwright';
import { createServer } from 'node:http';

// Same-origin profile marker detects navigation mistakenly intercepted by the player's worker.
const upstream = process.env.UI_TEST_URL || 'http://127.0.0.1:4173';
const server = createServer(async (request, response) => {
  if (request.url.startsWith('/profile/')) {
    response.writeHead(200, { 'Content-Type': 'text/html' });
    response.end('<!doctype html><title>Musica Profile</title><h1 id="profile-marker">Profile</h1>');
    return;
  }
  if (request.url.startsWith('/api/')) {
    response.writeHead(401, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    response.end('{"error":"unauthorized"}');
    return;
  }
  try {
    const result = await fetch(new URL(request.url, upstream));
    response.writeHead(result.status, { 'Content-Type': result.headers.get('content-type') || 'application/octet-stream' });
    response.end(Buffer.from(await result.arrayBuffer()));
  } catch {
    response.writeHead(502);
    response.end();
  }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const base = `http://127.0.0.1:${server.address().port}`;

const edge = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const browser = await chromium.launch({ headless: true,
  executablePath: process.env.CHROMIUM_PATH || (existsSync(edge) ? edge : undefined) });
const context = await browser.newContext();
const page = await context.newPage();
const errors = [];
page.on('pageerror', (error) => errors.push(error.message));
try {
  await page.goto(base);
  await page.evaluate(() => navigator.serviceWorker.ready.then(() => true));
  // A newly activated worker controls the next navigation; Edge can finish registration asynchronously.
  for (let attempt = 0; attempt < 10; attempt++) {
    await page.reload();
    if (await page.evaluate(() => Boolean(navigator.serviceWorker.controller))) break;
    await page.waitForTimeout(200);
  }
  assert.equal(await page.evaluate(() => Boolean(navigator.serviceWorker.controller)), true);
  const urls = await page.evaluate(async () => {
    const output = [];
    for (const name of await caches.keys()) for (const request of await (await caches.open(name)).keys()) output.push(request.url);
    return output;
  });
  assert.ok(urls.some((url) => new URL(url).pathname.endsWith('/index.html')));
  assert.ok(urls.every((url) => !new URL(url).pathname.startsWith('/api/')), 'private API must never enter shell cache');
  await page.goto(`${base}/profile/?return_to=${encodeURIComponent(base)}`);
  await page.locator('#profile-marker').waitFor();
  assert.equal(await page.title(), 'Musica Profile', 'player worker must not substitute its shell for profile');
  await page.goto(base);
  await context.setOffline(true); await page.reload();
  await page.locator('.brand').first().waitFor();
  assert.equal(await page.locator('#connection').isVisible(), true);
  assert.equal(await page.locator('#player-play').isDisabled(), true);
  assert.deepEqual(errors, []);
  console.log('PASS: production service worker, shell precache without API/audio, offline shell and offline indicator.');
} finally {
  await browser.close();
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
}
