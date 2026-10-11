import { t } from '../../shared/i18n';
import { errorMessage } from '../../shared/api/errors';
import { spotifyApi } from './api';
import {
  combineSpotifyExports,
  maxExportBytes,
  parseSpotifyExport,
  type SpotifyImport,
} from './parser';

export class SpotifyState {
  input = $state.raw<SpotifyImport | null>(null);
  preview = $state.raw<{ tracks: number; skipped: number } | null>(null);
  busy = $state(false);
  readingFiles = $state(false);
  error = $state('');
  notice = $state('');
  open = $state(false);
  private reading = 0;
  private generation = 0;
  constructor(private readonly changed: (id?: string) => Promise<void>) {}
  reset(): void {
    this.generation++;
    this.reading++;
    this.input = null;
    this.preview = null;
    this.busy = false;
    this.readingFiles = false;
    this.error = '';
    this.notice = '';
    this.open = false;
  }
  async read(files: File[]): Promise<void> {
    if (this.busy) return;
    const version = ++this.reading;
    this.input = null;
    this.preview = null;
    this.error = '';
    this.notice = '';
    this.readingFiles = true;
    try {
      if (!files.length || files.length > 2) throw new Error(t('spotify.selectFiles'));
      const parsed = await Promise.all(
        files.map(async (file) => {
          if (file.size > maxExportBytes)
            throw new Error(t('spotify.fileTooLarge', { filename: file.name }));
          try {
            return parseSpotifyExport(
              JSON.parse((await file.text()).replace(/^\uFEFF/, '')) as unknown,
            );
          } catch (error) {
            throw new Error(
              `${file.name}: ${error instanceof SyntaxError ? t('spotify.invalidJson') : errorMessage(error)}`,
            );
          }
        }),
      );
      if (version !== this.reading) return;
      const combined = combineSpotifyExports(parsed);
      this.input = combined.input;
      this.preview = combined;
    } catch (error) {
      if (version === this.reading) this.error = errorMessage(error);
    } finally {
      if (version === this.reading) this.readingFiles = false;
    }
  }
  async start(): Promise<void> {
    if (!this.input || this.busy) return;
    const generation = this.generation;
    this.busy = true;
    this.error = '';
    this.notice = '';
    try {
      const result = await spotifyApi.importSpotify(this.input);
      if (generation !== this.generation) return;
      this.input = null;
      this.notice = t('spotify.imported', {
        playlists: result.playlists.length,
        tracks: result.tracks,
      });
      await this.changed(result.playlists[0]);
    } catch (error) {
      if (generation === this.generation) this.error = errorMessage(error);
    } finally {
      if (generation === this.generation) this.busy = false;
    }
  }
}
