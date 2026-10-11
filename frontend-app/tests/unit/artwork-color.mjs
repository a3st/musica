import assert from 'node:assert/strict';
import { moduleUrl } from '../helpers/typescript.mjs';

const { artworkColor } = await import(moduleUrl(new URL('../../src/features/playlists/color.ts', import.meta.url)));
const pixels = (...colors) => new Uint8ClampedArray(colors.flat());
assert.deepEqual(artworkColor(pixels([90, 40, 170, 255], [90, 40, 170, 255], [0, 0, 0, 255], [255, 255, 255, 255])), [90, 40, 170]);
assert.equal(artworkColor(pixels([200, 40, 10, 0])), null, 'transparent pixels do not tint the playlist');
assert.equal(artworkColor(pixels([255, 255, 255, 255], [0, 0, 0, 255])), null, 'monochrome borders use the fallback');
assert.deepEqual(artworkColor(pixels([20, 120, 200, 255])), [20, 120, 200]);
console.log('PASS: cover colors, transparent pixels and monochrome fallbacks.');
