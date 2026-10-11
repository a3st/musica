import { webSearchApi } from './api';
import { errorMessage } from '../../shared/api/errors';
import type { SearchTrack } from './model';
import { searchTrackKey } from './model';
import type { Track } from '../tracks/model';

export class WebSearchState {
  query = $state('');
  tracks = $state<SearchTrack[]>([]);
  library = $state<Track[]>([]);
  loading = $state(false);
  searched = $state(false);
  error = $state('');
  additions = $state<Record<string, 'adding' | 'added'>>({});
  playingTrackKey = $state<string | null>(null);
  playingTrackId = $state<string | null>(null);
  private trackIds = new Map<string, string>();
  private pendingAdditions = new Map<string, Promise<string>>();
  private searchController?: AbortController;
  private additionsController = new AbortController();
  private version = 0;

  constructor(private readonly refresh: () => Promise<void>) {}

  setQuery(query: string): void {
    this.cancelSearch();
    this.query = query;
    this.tracks = [];
    this.library = [];
    this.searched = false;
    this.error = '';
  }

  async search(): Promise<void> {
    const query = this.query.trim();
    this.cancelSearch();
    if (query.length < 2 || new TextEncoder().encode(query).length > 256) return;
    const version = this.version;
    const controller = new AbortController();
    this.searchController = controller;
    this.loading = true;
    this.searched = true;
    this.error = '';
    this.tracks = [];
    this.library = [];
    try {
      const result = await webSearchApi.search(query, controller.signal);
      if (version === this.version) {
        this.library = result.library;
        this.tracks = result.catalog;
      }
    } catch (error) {
      if (version === this.version && !controller.signal.aborted) this.error = errorMessage(error);
    } finally {
      if (version === this.version) this.loading = false;
    }
  }

  add(track: SearchTrack, signal?: AbortSignal): Promise<string> {
    const key = searchTrackKey(track);
    const id = this.trackIds.get(key);
    if (id) return Promise.resolve(id);
    const pending = this.pendingAdditions.get(key);
    if (pending) return pending;

    const promise = this.addTrack(track, signal);
    this.pendingAdditions.set(key, promise);
    void promise
      .finally(() => {
        if (this.pendingAdditions.get(key) === promise) this.pendingAdditions.delete(key);
      })
      .catch(() => {});
    return promise;
  }

  /** Готовит общий трек для плеера, не добавляя его в личную библиотеку. */
  prepare(track: SearchTrack, signal: AbortSignal): Promise<string> {
    return webSearchApi.add(
      track,
      AbortSignal.any([signal, this.additionsController.signal]),
      false,
    );
  }

  private async addTrack(track: SearchTrack, signal?: AbortSignal): Promise<string> {
    const key = searchTrackKey(track);
    const controller = this.additionsController;
    const combined = signal ? AbortSignal.any([signal, controller.signal]) : controller.signal;
    this.additions[key] = 'adding';
    try {
      const id = await webSearchApi.add(track, combined);
      combined.throwIfAborted();
      this.trackIds.set(key, id);
      this.additions[key] = 'added';
      await this.refresh();
      combined.throwIfAborted();
      return id;
    } catch (error) {
      if (!controller.signal.aborted && this.additions[key] !== 'added') delete this.additions[key];
      throw error;
    }
  }

  cancelSearch(): void {
    this.version++;
    this.searchController?.abort();
    this.searchController = undefined;
    this.loading = false;
  }

  reset(): void {
    this.cancelSearch();
    this.additionsController.abort();
    this.additionsController = new AbortController();
    this.query = '';
    this.tracks = [];
    this.library = [];
    this.searched = false;
    this.error = '';
    this.additions = {};
    this.trackIds.clear();
    this.pendingAdditions.clear();
    this.playingTrackKey = null;
    this.playingTrackId = null;
  }
}
