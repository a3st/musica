import { playlistsApi } from '../playlists/api';
import type { Playlist, PlaylistSummary } from '../playlists/model';
import type { Track } from '../tracks/model';
import type { SearchTrack } from '../web-search/model';
import { searchTrackKey } from '../web-search/model';
import { WebSearchState } from '../web-search/state.svelte';
import { errorMessage } from '../../shared/api/errors';

export interface LocalResult {
  track: Track;
  playlistId: string;
}

export type RecentResult =
  { kind: 'local'; result: LocalResult } | { kind: 'web'; track: SearchTrack };

/** Searches the accessible library before consulting the external catalog. */
export class SearchState {
  readonly web: WebSearchState;
  query = $state('');
  open = $state(false);
  loading = $state(false);
  searched = $state(false);
  error = $state('');
  local = $state<LocalResult[]>([]);
  recent = $state<RecentResult[]>([]);
  private timer?: ReturnType<typeof setTimeout>;
  private controller?: AbortController;
  private version = 0;

  constructor(
    private readonly library: () => {
      items: PlaylistSummary[];
      selected: Playlist | null;
      canSearchWeb: boolean;
    },
    refresh: () => Promise<void>,
  ) {
    this.web = new WebSearchState(refresh);
  }

  setQuery(query: string): void {
    this.cancel();
    this.query = query;
    this.open = true;
    this.local = [];
    this.error = '';
    this.searched = false;
    this.web.setQuery(query);
    if (query.trim()) {
      this.loading = true;
      this.timer = setTimeout(() => void this.search(), 350);
    }
  }

  async search(): Promise<void> {
    this.cancel();
    const query = this.query.trim();
    if (!query) return;
    this.open = true;
    this.loading = true;
    this.searched = true;
    this.error = '';
    this.local = [];
    this.web.setQuery(query);
    const version = this.version;
    const controller = new AbortController();
    this.controller = controller;

    try {
      const { items, selected, canSearchWeb } = this.library();
      const playlists: Playlist[] = selected ? [selected] : [];
      const remaining = items.filter((item) => item.id !== selected?.id);
      let index = 0;
      // Bound concurrent requests; a failed library read must not become a false catalog miss.
      await Promise.all(
        Array.from({ length: Math.min(4, remaining.length) }, async () => {
          while (index < remaining.length && !controller.signal.aborted) {
            const item = remaining[index++];
            playlists.push(await playlistsApi.playlist(item.id, controller.signal));
          }
        }),
      );
      if (version !== this.version) return;

      const words = query.toLocaleLowerCase().split(/\s+/);
      const seen = new Set<string>();
      const matches: LocalResult[] = [];
      for (const playlist of playlists) {
        for (const track of playlist.tracks) {
          const text = `${track.title} ${track.artist}`.toLocaleLowerCase();
          if (seen.has(track.id) || !words.every((word) => text.includes(word))) continue;
          seen.add(track.id);
          matches.push({ track, playlistId: playlist.id });
        }
      }
      this.local = matches;
      if (!matches.length && query.length >= 2 && canSearchWeb) await this.web.search();
    } catch (error) {
      if (version === this.version && !controller.signal.aborted) {
        this.error = errorMessage(error);
        controller.abort();
      }
    } finally {
      if (version === this.version) this.loading = false;
    }
  }

  remember(result: RecentResult): void {
    const key = (item: RecentResult) =>
      item.kind === 'local' ? `local:${item.result.track.id}` : `web:${searchTrackKey(item.track)}`;
    this.recent = [result, ...this.recent.filter((item) => key(item) !== key(result))].slice(0, 8);
  }

  close(): void {
    this.open = false;
    if (this.loading) this.searched = false;
    this.cancel();
  }

  private cancel(): void {
    clearTimeout(this.timer);
    this.timer = undefined;
    this.version++;
    this.controller?.abort();
    this.controller = undefined;
    this.web.cancelSearch();
    this.loading = false;
  }

  reset(): void {
    this.close();
    this.web.reset();
    this.query = '';
    this.local = [];
    this.recent = [];
    this.error = '';
    this.searched = false;
  }
}
