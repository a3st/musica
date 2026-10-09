import { readFileSync, existsSync } from 'node:fs';
import { chromium } from 'playwright';
import { fileURLToPath } from 'node:url';

// Render the repo-native SVG at the PWA icon sizes.
const edge = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_PATH || (existsSync(edge) ? edge : undefined) });
try {
  const svg = readFileSync(new URL('../public/icon.svg', import.meta.url), 'utf8');
  for (const size of [192, 512]) {
    const page = await browser.newPage({ viewport: { width: size, height: size }, deviceScaleFactor: 1 });
    await page.setContent(`<style>html,body{margin:0;background:transparent}svg{display:block;width:100vw;height:100vh}</style>${svg}`);
    await page.screenshot({ path: fileURLToPath(new URL(`../public/icon-${size}.png`, import.meta.url)), omitBackground: true });
    await page.close();
  }
} finally { await browser.close(); }
