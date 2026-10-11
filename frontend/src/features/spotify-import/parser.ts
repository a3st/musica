import { t } from '../../shared/i18n';
export interface SpotifyTrack {
  title: string;
  artist: string;
  spotify_uri?: string;
}
export interface SpotifyPlaylist {
  title: string;
  description: string;
  tracks: SpotifyTrack[];
}
export interface SpotifyImport {
  playlists: SpotifyPlaylist[];
  library: SpotifyTrack[];
}
export interface SpotifyExport {
  kind: 'playlists' | 'library';
  playlists: SpotifyPlaylist[];
  library: SpotifyTrack[];
  skipped: number;
}
export const maxExportBytes = 16 * 1024 * 1024;

/** Filters individual playlist memberships without mutating the parsed export. */
export function selectSpotifyTracks(
  input: SpotifyImport,
  excluded: ReadonlySet<string>,
): SpotifyImport {
  return {
    playlists: input.playlists.map((playlist, group) => ({
      ...playlist,
      tracks: playlist.tracks.filter((_, index) => !excluded.has(`playlist:${group}:${index}`)),
    })),
    library: input.library.filter((_, index) => !excluded.has(`library:${index}`)),
  };
}

function object(value: unknown): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value))
    throw new Error(t('spotify.invalidStructure'));
  return value as Record<string, unknown>;
}
function array(value: unknown): unknown[] {
  if (!Array.isArray(value)) throw new Error(t('spotify.expectedList'));
  return value;
}
function text(value: unknown, max: number, empty = false): string {
  if (typeof value !== 'string') throw new Error(t('spotify.missingMetadata'));
  const normalized = value.trim();
  if (
    (!empty && !normalized) ||
    [...normalized].length > max ||
    /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(normalized) ||
    (!empty && /[\t\r\n]/.test(normalized))
  )
    throw new Error(t('spotify.invalidMetadata'));
  return normalized;
}
function track(value: unknown, library: boolean): SpotifyTrack | null {
  const r = object(value);
  const uri = library ? r.uri : r.trackUri;
  if (
    typeof uri === 'string' &&
    (uri.startsWith('spotify:local:') || uri.startsWith('spotify:episode:'))
  )
    return null;
  const result: SpotifyTrack = {
    title: text(library ? r.track : r.trackName, 256),
    artist: text(library ? r.artist : r.artistName, 256),
  };
  if (uri !== null && uri !== undefined && uri !== '') {
    if (typeof uri !== 'string' || !/^spotify:track:[a-zA-Z0-9]{22}$/.test(uri))
      throw new Error(t('spotify.invalidUri'));
    result.spotify_uri = uri;
  }
  return result;
}

// Only the two account-data exports are accepted, never streaming history or arbitrary URLs.
export function parseSpotifyExport(value: unknown): SpotifyExport {
  const r = object(value);
  let skipped = 0;
  if ('playlists' in r) {
    const playlists = array(r.playlists).map((value): SpotifyPlaylist => {
      const p = object(value);
      const tracks: SpotifyTrack[] = [];
      for (const value of array(p.items)) {
        const item = object(value);
        if (item.track === null || item.track === undefined) {
          if (item.episode != null || item.localTrack != null) {
            skipped++;
            continue;
          }
          throw new Error(t('spotify.missingTrack'));
        }
        const parsed = track(item.track, false);
        if (parsed) tracks.push(parsed);
        else skipped++;
      }
      return {
        title: text(p.name, 256),
        description: p.description == null ? '' : text(p.description, 4096, true),
        tracks,
      };
    });
    return { kind: 'playlists', playlists, library: [], skipped };
  }
  if ('tracks' in r) {
    const library: SpotifyTrack[] = [];
    for (const value of array(r.tracks)) {
      const parsed = track(value, true);
      if (parsed) library.push(parsed);
      else skipped++;
    }
    return { kind: 'library', playlists: [], library, skipped };
  }
  throw new Error(t('spotify.unsupportedExport'));
}

export function trackIdentity(track: SpotifyTrack): string {
  const lower = (s: string) => s.replace(/[A-Z]/g, (c) => c.toLowerCase());
  return track.spotify_uri ?? `${lower(track.artist)}\0${lower(track.title)}`;
}
export function combineSpotifyExports(exports: SpotifyExport[]): {
  input: SpotifyImport;
  tracks: number;
  skipped: number;
} {
  const kinds = new Set<string>();
  const input: SpotifyImport = { playlists: [], library: [] };
  let skipped = 0;
  for (const file of exports) {
    if (kinds.has(file.kind)) throw new Error(t('spotify.duplicateExport'));
    kinds.add(file.kind);
    input.playlists.push(...file.playlists);
    input.library.push(...file.library);
    skipped += file.skipped;
  }
  const all = [...input.library, ...input.playlists.flatMap((p) => p.tracks)];
  if (!all.length) throw new Error(t('spotify.noTracks'));
  if (all.length > 5000 || input.playlists.length > 100) throw new Error(t('spotify.importLimit'));
  if (new TextEncoder().encode(JSON.stringify(input)).length > 4 * 1024 * 1024)
    throw new Error(t('spotify.metadataLimit'));
  return { input, tracks: new Set(all.map(trackIdentity)).size, skipped };
}
