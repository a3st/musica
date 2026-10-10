import { playlistsApi } from './api';
import type { Playlist, PlaylistSummary } from './model';

export class PlaylistsState {
  items = $state<PlaylistSummary[]>([]);
  selected = $state<Playlist | null>(null);
  search = $state('');
  filter = $state('');
  shareToken = $state<string | null>(null);
  readonly trackTokens = new Map<string, string>();
  readonly shareLinks = new Map<string, string>();
  private version = 0;
  get visibleTracks() {
    return (this.selected?.tracks ?? []).filter((track) =>
      `${track.title} ${track.artist}`
        .toLocaleLowerCase()
        .includes(this.search.toLocaleLowerCase()),
    );
  }
  get visiblePlaylists() {
    return this.items.filter((item) =>
      item.title.toLocaleLowerCase().includes(this.filter.toLocaleLowerCase()),
    );
  }
  writable(id: string): boolean {
    return this.items.some((item) => item.id === id && item.role !== 'viewer');
  }
  async select(id: string, token: string | null = null): Promise<boolean> {
    const version = ++this.version;
    const playlist = token
      ? await playlistsApi.sharedPlaylist(token)
      : await playlistsApi.playlist(id);
    if (version !== this.version) return false;
    if (this.selected?.id !== playlist.id) this.search = '';
    this.selected = playlist;
    this.shareToken = token;
    if (token) for (const track of playlist.tracks) this.trackTokens.set(track.id, token);
    return true;
  }
  async list(): Promise<void> {
    this.items = await playlistsApi.playlists();
  }
  async poll(): Promise<void> {
    if (
      !this.selected?.tracks.some(
        (track) => track.status !== 'streamed' || track.duration_seconds == null,
      )
    )
      return;
    const id = this.selected.id;
    const version = this.version;
    const updated = this.shareToken
      ? await playlistsApi.sharedPlaylist(this.shareToken)
      : await playlistsApi.playlist(id);
    if (
      version === this.version &&
      this.selected?.id === id &&
      JSON.stringify(updated.tracks) !== JSON.stringify(this.selected.tracks)
    )
      this.selected = updated;
  }
  reset(): void {
    this.version++;
    this.items = [];
    this.selected = null;
    this.shareToken = null;
    this.search = '';
    this.filter = '';
    this.trackTokens.clear();
    this.shareLinks.clear();
  }
}
