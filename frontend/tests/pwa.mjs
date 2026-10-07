import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { chromium } from 'playwright';

const edge = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const browser = await chromium.launch({ headless: true,
  executablePath: process.env.CHROMIUM_PATH || (existsSync(edge) ? edge : undefined) });
const context = await browser.newContext();
const page = await context.newPage();
const errors = [];
page.on('pageerror', (error) => errors.push(error.message));
try {
  await page.goto(process.env.UI_TEST_URL || 'http://127.0.0.1:4173');
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
  await context.setOffline(true); await page.reload();
  await page.locator('.brand').first().waitFor();
  assert.equal(await page.locator('#connection').isVisible(), true);
  assert.equal(await page.locator('#player-play').isDisabled(), true);
  assert.deepEqual(errors, []);
  console.log('PASS: production service worker, shell precache without API/audio, offline shell and offline indicator.');
} finally { await browser.close(); }
