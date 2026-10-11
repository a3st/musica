import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { moduleUrl } from '../helpers/typescript.mjs';

const { audioSettings } = await import(moduleUrl(new URL('../../src/features/settings/model.ts', import.meta.url)));
assert.equal(audioSettings({ preset: 'unknown' }).preset, 'flat');
assert.equal(audioSettings({ preset: 'toString' }).preset, 'flat');
assert.deepEqual(audioSettings({ preset: 'custom', custom: [NaN, 0, 0, 0, 0, 0] }).gains, [0, 0, 0, 0, 0, 0]);
assert.deepEqual(audioSettings({ preset: 'custom', custom: [8, 3, 0, -2, 1, 4] }).gains, [8, 3, 0, -2, 1, 4]);
assert.deepEqual(audioSettings({ preset: 'bass', gains: [99, 99] }).gains, [6, 4, 1, 0, -1, 0]);

let Processor;
runInNewContext(readFileSync(new URL('../../public/audio/normalizer.js', import.meta.url), 'utf8'), {
  sampleRate: 48000,
  AudioWorkletProcessor: class { port = {}; },
  registerProcessor: (_, implementation) => { Processor = implementation; },
});
const processor = new Processor();
const render = (amplitude, blocks = 1) => {
  const input = new Float32Array(128).fill(amplitude);
  const output = new Float32Array(128);
  for (let i = 0; i < blocks; i++) processor.process([[input]], [[output]]);
  return output[0];
};
assert.ok(Math.abs(render(0.3) - 0.3) < 0.00001, 'disabled normalization preserves samples');
processor.port.onmessage({ data: { enabled: true, volume: 1 } });
assert.ok(render(0.8, 4000) < 0.3, 'loud audio is attenuated');
processor.port.onmessage({ data: { reset: true } });
assert.ok(render(0.03, 8000) > 0.04, 'quiet audio receives bounded amplification');
assert.ok(render(1.5) <= 0.980001, 'peak limiter prevents clipping');
processor.port.onmessage({ data: { reset: true } });
processor.port.onmessage({ data: { enabled: true, volume: 0.1 } });
assert.ok(render(0.08, 4000) < 0.03, 'normalization respects the user volume');
processor.port.onmessage({ data: { enabled: false, volume: 1 } });
assert.ok(Math.abs(render(0.3) - 0.3) < 0.00001);
console.log('PASS: audio preferences validation, normalization bypass, leveling, clipping and user volume.');
