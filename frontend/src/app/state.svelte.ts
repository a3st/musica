import { AuthState } from '../features/auth/state.svelte';
import { authApi } from '../features/auth/api';
import { capabilitiesApi } from '../features/capabilities/api';
import type { Capabilities } from '../features/capabilities/model';
import { PlaylistsState } from '../features/playlists/state.svelte';
import { PlaylistEditorState } from '../features/playlists/editor.svelte';
import { PlayerState } from '../features/player/state.svelte';
import { UploadsState } from '../features/uploads/state.svelte';
import { SpotifyState } from '../features/spotify-import/state.svelte';
import { SearchState, type LocalResult } from '../features/search/state.svelte';
import { LanguageState } from '../shared/i18n/state.svelte';
import { ThemeState } from '../shared/theme/state.svelte';
import { MenuState } from '../shared/ui/menu.svelte';
import { ApiError, errorMessage } from '../shared/api/errors';
import { readNavigation, selectNavigation } from './navigation';
import { playlistMenu, trackMenu, webTrackMenu, serviceTrackMenu } from './menus';
import type { PlaylistSummary } from '../features/playlists/model';
import type { Track } from '../features/tracks/model';
import type { SearchTrack } from '../features/web-search/model';
import { searchTrackKey } from '../features/web-search/model';
import { waitForDownloadedTrack } from '../features/web-search/playback';
import { playlistsApi } from '../features/playlists/api';

export interface Confirmation {
  title: string;
  description: string;
  remove: () => Promise<void>;
}
export class Application {
  capabilities = $state<Capabilities>({ web_search: false, spotify_import: false });
  readonly auth = new AuthState();
  readonly library = new PlaylistsState();
  readonly language = new LanguageState();
  readonly theme = new ThemeState();
  readonly menu = new MenuState();
  readonly player = new PlayerState(
    (message) => this.notify(message),
    () => this.auth.user?.id ?? null,
    (id) => this.library.trackTokens.get(id) ?? null,
  );
  readonly uploads = new UploadsState(
    () => this.refresh(),
    (message) => this.notify(message),
  );
  readonly spotify = new SpotifyState((id) => this.refresh(id));
  readonly search = new SearchState(
    () => !!this.auth.user && this.capabilities.web_search,
    () => this.refresh(),
  );
  readonly editor = new PlaylistEditorState(
    (id) => {
      this.library.shareLinks.delete(id);
      return this.refresh(id);
    },
    (message) => this.notify(message),
  );
  authOpen = $state(false);
  sessionLoading = $state(true);
  sessionError = $state('');
  libraryOpen = $state(false);
  confirmation = $state.raw<Confirmation | null>(null);
  confirmationBusy = $state(false);
  toast = $state('');
  online = $state(navigator.onLine);
  updateAvailable = $state(false);
  private toastTimer?: ReturnType<typeof setTimeout>;
  private polling = false;
  private disposed = false;
  private sessionVersion = 0;
  notify(message: string): void {
    clearTimeout(this.toastTimer);
    this.toast = message;
    this.toastTimer = setTimeout(() => {
      this.toast = '';
    }, 6000);
  }
  run(task: Promise<unknown>): void {
    void task.catch((error) => {
      if (!this.disposed) this.notify(errorMessage(error));
    });
  }
  requireLogin(): boolean {
    if (this.auth.user) return true;
    this.authOpen = true;
    return false;
  }
  async signIn(username: string, password: string, register: boolean): Promise<void> {
    // Invalidate requests from the previous session before replacing its cookie.
    this.reset();
    this.authOpen = true;
    await authApi.signIn(username, password, register);
    await this.openSession();
  }
  async openSession(): Promise<void> {
    const version = ++this.sessionVersion;
    this.sessionLoading = true;
    this.sessionError = '';
    try {
      await this.loadSession(version);
    } catch (error) {
      if (version !== this.sessionVersion || this.disposed) return;
      if (error instanceof ApiError && error.status === 401) {
        this.reset();
        this.authOpen = true;
      } else {
        this.sessionError = errorMessage(error);
        this.authOpen = !this.auth.user && !this.library.selected;
        if (this.library.selected || this.authOpen) this.notify(this.sessionError);
      }
    } finally {
      if (version === this.sessionVersion && !this.disposed) this.sessionLoading = false;
    }
  }
  private async loadSession(version: number): Promise<void> {
    const capabilities = await capabilitiesApi.read();
    if (version !== this.sessionVersion || this.disposed) return;
    this.capabilities = capabilities;

    const navigation = readNavigation();
    try {
      await this.auth.load();
    } catch (error) {
      if (version !== this.sessionVersion || this.disposed) return;
      if (!(
        error instanceof ApiError &&
        error.status === 401 &&
        (navigation.id || navigation.token)
      ))
        throw error;
      this.auth.reset();
      this.library.reset();
    }
    if (version !== this.sessionVersion || this.disposed) return;
    this.authOpen = false;
    if (this.auth.user) await this.library.list();
    if (version !== this.sessionVersion || this.disposed) return;
    if (navigation.token) {
      if (!/^[0-9a-f]{64}$/.test(navigation.token))
        throw new Error(this.language.t('share.invalidLink'));
      await this.selectPlaylist('', navigation.token);
    } else if (navigation.id) {
      if (!/^[0-9a-f-]{36}$/i.test(navigation.id))
        throw new Error(this.language.t('share.invalidLink'));
      await this.selectPlaylist(navigation.id);
    } else await this.refresh();
    if (version !== this.sessionVersion || this.disposed) return;
  }
  async start(): Promise<void> {
    await this.openSession();
  }
  async selectPlaylist(
    id: string,
    token: string | null = null,
    showPlaylist = true,
  ): Promise<void> {
    if (showPlaylist) this.search.close();
    this.menu.close(false);
    this.libraryOpen = false;
    if (await this.library.select(id, token)) {
      const selected = this.library.selected!;
      this.player.engine.updateMetadata(selected.tracks);
      selectNavigation(selected.id, token);
      if (this.player.cover?.id === selected.id) this.player.cover = selected;
    }
    this.libraryOpen = false;
  }
  async refresh(id?: string): Promise<void> {
    const user = this.auth.user;
    if (!user || this.disposed) return;
    await this.library.list();
    const candidate = id ?? this.library.selected?.id ?? user.default_playlist_id;
    if (!id && this.library.shareToken)
      await this.selectPlaylist(candidate, this.library.shareToken, false);
    else
      await this.selectPlaylist(
        this.library.items.some((item) => item.id === candidate)
          ? candidate
          : user.default_playlist_id,
        null,
        false,
      );
  }

  async playSearchResult(result: LocalResult): Promise<void> {
    this.search.remember({ kind: 'local', result });
    await this.selectPlaylist(result.playlistId);
    if (this.library.selected?.id !== result.playlistId) return;
    const track = this.library.selected?.tracks.find((item) => item.id === result.track.id);
    if (track) this.play(track);
  }
  play(track: Track): void {
    if (
      this.player.value.current?.id === track.id &&
      (this.player.value.loading || this.player.engine.audio.src)
    ) {
      this.player.engine.toggle();
      return;
    }
    this.player.cover = this.library.selected;
    this.run(this.player.engine.load(track, this.library.visibleTracks));
  }

  async addWebTrack(track: SearchTrack, playlistId?: string): Promise<void> {
    if (!this.requireLogin()) return;
    this.search.remember({ kind: 'web', track });
    const version = this.sessionVersion;
    const id = await this.search.web.add(track);
    if (version !== this.sessionVersion || this.disposed) return;
    if (playlistId && playlistId !== this.auth.user?.default_playlist_id) {
      await playlistsApi.attachTrack(playlistId, id);
      await this.refresh();
      this.notify(this.language.t('tracks.addedToPlaylist'));
    }
  }

  async playWebTrack(track: SearchTrack): Promise<void> {
    const user = this.auth.user;
    if (!this.requireLogin() || !user) return;
    this.search.remember({ kind: 'web', track });
    this.search.web.playingTrackKey = searchTrackKey(track);
    await this.player.engine.loadDeferred(async (signal) => {
      const id = await this.search.web.prepare(track, signal);
      signal.throwIfAborted();
      return waitForDownloadedTrack(id, signal);
    });
  }

  async playServiceTrack(track: Track): Promise<void> {
    if (!this.requireLogin()) return;
    this.search.remember({ kind: 'service', track });
    this.player.cover = null;
    await this.player.engine.load(track, [track], true);
  }

  async addServiceTrack(track: Track, playlistId?: string): Promise<void> {
    const user = this.auth.user;
    if (!this.requireLogin() || !user) return;
    const target = playlistId ?? user.default_playlist_id;
    const addingToUploads = target === user.default_playlist_id;
    if (addingToUploads && this.search.serviceAdditions[track.id]) return;
    const version = this.sessionVersion;
    if (addingToUploads) this.search.serviceAdditions[track.id] = 'adding';
    try {
      await playlistsApi.attachTrack(target, track.id);
      if (version !== this.sessionVersion || this.disposed) return;
      if (addingToUploads) this.search.serviceAdditions[track.id] = 'added';
      this.search.remember({ kind: 'service', track });
      await this.refresh();
      if (version === this.sessionVersion && !this.disposed)
        this.notify(this.language.t('tracks.addedToPlaylist'));
    } catch (error) {
      if (version === this.sessionVersion && this.search.serviceAdditions[track.id] !== 'added')
        delete this.search.serviceAdditions[track.id];
      throw error;
    }
  }

  showServiceTrackMenu(track: Track, origin: HTMLElement): void {
    this.menu.toggle(serviceTrackMenu(this, track), origin);
  }

  showWebTrackMenu(track: SearchTrack, origin: HTMLElement): void {
    this.menu.toggle(webTrackMenu(this, track), origin);
  }
  shufflePlaylist(): void {
    if (!this.player.value.shuffle) this.player.engine.toggleShuffle();
    const tracks = this.library.visibleTracks.filter((track) => track.status !== 'pending');
    if (tracks.length) {
      this.player.cover = this.library.selected;
      this.run(
        this.player.engine.load(
          tracks[Math.floor(Math.random() * tracks.length)],
          this.library.visibleTracks,
        ),
      );
    }
  }
  showTrackMenu(track: Track, origin: HTMLElement, point?: { x: number; y: number }): void {
    const items = trackMenu(this, track);
    if (point) this.menu.open(items, origin, point);
    else this.menu.toggle(items, origin);
  }
  showPlaylistMenu(
    playlist: PlaylistSummary,
    origin: HTMLElement,
    point: { x: number; y: number },
  ): void {
    this.menu.open(playlistMenu(this, playlist), origin, point);
  }
  createPlaylist(): void {
    if (this.requireLogin()) {
      this.libraryOpen = false;
      this.run(this.editor.edit());
    }
  }
  upload(): void {
    if (this.requireLogin()) {
      this.libraryOpen = false;
      this.uploads.open = true;
    }
  }
  importSpotify(): void {
    if (!this.capabilities.spotify_import) return;

    if (this.requireLogin()) {
      this.libraryOpen = false;
      this.uploads.open = false;
      this.spotify.open = true;
    }
  }
  async logout(): Promise<void> {
    if (this.uploads.busy) {
      this.notify(this.language.t('app.finishOrCancelUploads'));
      return;
    }
    await authApi.logout();
    this.reset();
    location.reload();
  }
  async confirm(): Promise<void> {
    if (!this.confirmation || this.confirmationBusy) return;
    this.confirmationBusy = true;
    try {
      await this.confirmation.remove();
      this.confirmation = null;
    } catch (error) {
      this.notify(errorMessage(error));
    } finally {
      this.confirmationBusy = false;
    }
  }
  async poll(): Promise<void> {
    if (
      !this.auth.user ||
      this.sessionLoading ||
      !this.online ||
      document.hidden ||
      this.polling ||
      this.disposed
    )
      return;
    const version = this.sessionVersion;
    this.polling = true;
    try {
      await this.uploads.poll();
      if (version !== this.sessionVersion || this.disposed) return;
      await this.library.poll();
      if (version !== this.sessionVersion || this.disposed) return;
      if (this.library.selected) this.player.engine.updateMetadata(this.library.selected.tracks);
    } catch (error) {
      if (version !== this.sessionVersion || this.disposed) return;
      if (error instanceof ApiError && error.status === 401) {
        this.reset();
        this.notify(this.language.t('app.sessionExpired'));
        this.authOpen = true;
      }
    } finally {
      this.polling = false;
    }
  }
  reset(): void {
    this.sessionVersion++;
    clearTimeout(this.toastTimer);
    this.toast = '';
    this.sessionLoading = false;
    this.sessionError = '';
    this.player.engine.stop();
    this.uploads.reset();
    this.spotify.reset();
    this.search.reset();
    this.editor.reset();
    this.auth.reset();
    this.library.reset();
    this.menu.close(false);
  }
  dispose(): void {
    this.disposed = true;
    this.sessionVersion++;
    clearTimeout(this.toastTimer);
    this.player.dispose();
    this.uploads.reset();
    this.spotify.reset();
    this.search.reset();
    this.editor.reset();
  }
}
