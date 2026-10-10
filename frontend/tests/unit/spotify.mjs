import assert from 'node:assert/strict';
import { moduleUrl } from '../helpers/typescript.mjs';
const { parseSpotifyExport: parse, combineSpotifyExports: combine } = await import(moduleUrl(new URL('../../src/features/spotify-import/parser.ts', import.meta.url)));
const uri = 'spotify:track:0123456789012345678901';
const playlists = parse({ playlists: [{ name: 'Плейлист', description: '<script>test</script>', items: [
  { track: { trackName: 'Get Lucky', artistName: 'Daft Punk', albumName: 'Random Access Memories', trackUri: uri } },
  { track: null, episode: { episodeName: 'Podcast' } }, { localTrack: { title: 'Local' } },
] }] });
const library = parse({ tracks: [{ artist: 'Daft Punk', track: 'Get Lucky', album: 'RAM', uri }], albums: [], artists: [] });
const result = combine([playlists, library]);
assert.equal(result.tracks, 1, 'one download for the same URI across files');
assert.equal(result.skipped, 2);
assert.equal(result.input.playlists[0].title, 'Плейлист');
assert.equal(result.input.library[0].artist, 'Daft Punk');
assert.equal(combine([library]).tracks, 1);
assert.throws(() => combine([library, library]), /по одному/);
assert.throws(() => parse({ tracks: [{ artist: null, track: 'Title' }] }));
assert.throws(() => parse({ playlists: [{ name: 'Playlist', items: [{}] }] }));
assert.throws(() => parse({ tracks: [{ artist: 'Artist', track: 'Title', uri: 'https://example.org' }] }));
assert.throws(() => parse({ tracks: [{ artist: 'Artist', track: 'a'.repeat(257) }] }));
assert.throws(() => combine([parse({ tracks: [] })]), /нет музыкальных/);
assert.throws(() => combine([parse({ tracks: Array(5001).fill({ artist: 'Artist', track: 'Title' }) })]), /5000/);
assert.throws(() => parse([{ endTime: 'Streaming history' }]));
assert.equal(combine([parse({ tracks: [{ artist: 'Artist', track: 'Title' }, { artist: 'ARTIST', track: ' title ' }] })]).tracks, 1);
console.log('PASS: Spotify exports, Unicode metadata, deduplication, skipped podcasts/local files, malformed data and import limits.');
