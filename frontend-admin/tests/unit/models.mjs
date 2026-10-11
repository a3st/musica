import assert from 'node:assert/strict';
import { moduleUrl } from '../helpers/typescript.mjs';

const { parseUser } = await import(moduleUrl(new URL('../../src/features/auth/model.ts', import.meta.url)));
const { parseStorage, formatBytes } = await import(moduleUrl(new URL('../../src/features/storage/model.ts', import.meta.url)));
const { parseUsers } = await import(moduleUrl(new URL('../../src/features/users/model.ts', import.meta.url)));
const user = { id: '11111111-1111-4111-8111-111111111111', username: 'fixture', role: 'admin' };

assert.equal(parseUser(user).role, 'admin');
assert.throws(() => parseUser({ ...user, role: ['admin'] }));
assert.throws(() => parseUser({ ...user, role: 'system' }));
assert.throws(() => parseUser({ ...user, id: '-'.repeat(36) }));
assert.throws(() => parseUser(null));
assert.equal(parseUsers([{ ...user, created_at: '2026-10-12T00:00:00Z', tracks: 3 }])[0].tracks, 3);
assert.throws(() => parseUsers([{ ...user, created_at: 'invalid', tracks: 3 }]));
assert.throws(() => parseUsers([{ ...user, created_at: '2026-10-12', tracks: -1 }]));

const storage = {
  source_bytes: 1024, user_bytes: 512, system_bytes: 512, orphaned_bytes: 0,
  tracks: 2, orphaned_tracks: 0, pending_tracks: 0, hls_segments: 12, cleanup_jobs: 0,
};
assert.deepEqual(parseStorage(storage), storage);
assert.throws(() => parseStorage({ ...storage, source_bytes: -1 }));
assert.throws(() => parseStorage({ ...storage, tracks: '2' }));
assert.throws(() => parseStorage({ ...storage, tracks: Number.MAX_SAFE_INTEGER + 1 }));
assert.equal(formatBytes(0, 'en-US'), '0 B');
assert.equal(formatBytes(1024, 'en-US'), '1 KiB');
console.log('PASS: profile roles, UUID, user counters and storage response validation.');
