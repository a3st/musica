import { webSearchApi } from './api';
import { errorMessage } from '../../shared/api/errors';
import type { SearchTrack } from './model';

export class WebSearchState {
  query = $state('');
  tracks = $state<SearchTrack[]>([]);
  loading = $state(false);
  searched = $state(false);
  error = $state('');
  additions = $state<Record<string, 'adding' | 'added'>>({});
  private searchController?: AbortController;
  private additionsController = new AbortController();
  private version = 0;

  constructor(private readonly refresh: () => Promise<void>) {}

  setQuery(query: string): void {
    this.cancelSearch();
    this.query = query;
    this.tracks = [];
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
    try {
      const tracks = await webSearchApi.search(query, controller.signal);
      if (version === this.version) this.tracks = tracks;
    } catch (error) {
      if (version === this.version && !controller.signal.aborted) this.error = errorMessage(error);
    } finally {
      if (version === this.version) this.loading = false;
    }
  }

  async add(track: SearchTrack): Promise<void> {
    if (this.additions[track.external_id]) return;
    const controller = this.additionsController;
    this.additions[track.external_id] = 'adding';
    try {
      await webSearchApi.add(track.external_id, controller.signal);
      if (controller.signal.aborted) return;
      this.additions[track.external_id] = 'added';
      await this.refresh();
    } catch (error) {
      if (controller.signal.aborted) return;
      if (this.additions[track.external_id] !== 'added') delete this.additions[track.external_id];
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
    this.searched = false;
    this.error = '';
    this.additions = {};
  }
}
