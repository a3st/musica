import { t } from '../../shared/i18n';
import { ApiError, errorMessage } from '../../shared/api/errors';
import { readPreference, writePreference } from '../../shared/utils/storage';
import { spotifyApi } from './api';
import { tracksApi } from '../tracks/api';
import {
  combineSpotifyExports,
  maxExportBytes,
  parseSpotifyExport,
  type SpotifyImport,
} from './parser';
import type { SpotifyImportStatus } from './model';

export class SpotifyState {
  input = $state.raw<SpotifyImport | null>(null);
  current = $state.raw<SpotifyImportStatus | null>(null);
  preview = $state.raw<{ tracks: number; skipped: number } | null>(null);
  busy = $state(false);
  readingFiles = $state(false);
  error = $state('');
  notice = $state('');
  open = $state(false);
  private reading = 0;
  private generation = 0;
  constructor(
    private readonly changed: (id?: string) => Promise<void>,
    private readonly userId: () => string | null,
  ) {}
  get failed(): number {
    return (
      this.current?.tracks.filter(
        (track) => track.download === 'failed' || track.preparation === 'failed',
      ).length ?? 0
    );
  }
  reset(): void {
    this.generation++;
    this.reading++;
    this.input = null;
    this.current = null;
    this.preview = null;
    this.busy = false;
    this.readingFiles = false;
    this.error = '';
    this.notice = '';
    this.open = false;
  }
  async restore(): Promise<void> {
    const user = this.userId();
    if (!user) return;
    const id = readPreference(`musica:spotify:${user}`);
    if (!id || !/^[0-9a-f-]{36}$/i.test(id)) return;
    this.current = { id, tracks: [] };
    try {
      await this.poll();
    } catch (error) {
      this.error = errorMessage(error);
    }
  }
  async read(files: File[]): Promise<void> {
    const version = ++this.reading;
    this.input = null;
    this.preview = null;
    this.error = '';
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
    this.current = null;
    this.error = '';
    try {
      const result = await spotifyApi.importSpotify(this.input);
      if (generation !== this.generation) return;
      this.input = null;
      this.current = { id: result.id, tracks: [] };
      const user = this.userId();
      if (user) writePreference(`musica:spotify:${user}`, result.id);
      this.notice = t('spotify.queued', { count: result.tracks });
      await this.changed(result.playlists[0]);
      await this.poll();
    } catch (error) {
      if (generation === this.generation) this.error = errorMessage(error);
    } finally {
      if (generation === this.generation) this.busy = false;
    }
  }
  async poll(): Promise<void> {
    const id = this.current?.id;
    const generation = this.generation;
    if (!id) return;
    try {
      const result = await spotifyApi.spotifyImportStatus(id);
      if (generation === this.generation && this.current?.id === id) {
        this.current = result;
        this.notice = '';
      }
    } catch (error) {
      if (error instanceof ApiError && error.status === 404 && generation === this.generation) {
        this.current = null;
        this.notice = t('spotify.tracksDeleted');
        return;
      }
      throw error;
    }
  }
  async retry(): Promise<void> {
    if (!this.current || this.busy) return;
    const generation = this.generation;
    this.busy = true;
    try {
      await spotifyApi.retrySpotifyImport(this.current.id);
      if (generation !== this.generation) return;
      for (const track of this.current.tracks)
        if (track.download === 'completed' && track.preparation === 'failed')
          await tracksApi.prepare(track.id);
      await this.poll();
      this.error = '';
    } catch (error) {
      if (generation === this.generation) this.error = errorMessage(error);
    } finally {
      if (generation === this.generation) this.busy = false;
    }
  }
}
