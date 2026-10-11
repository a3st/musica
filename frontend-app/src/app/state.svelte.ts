import { SettingsState } from '../features/settings/state.svelte';
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
import { tracksApi } from '../features/tracks/api';
import { playlistsApi } from '../features/playlists/api';

/** Описание подтверждаемого удаления и операция, выполняемая только после согласия. */
export interface Confirmation {
  title: string;
  description: string;
  remove: () => Promise<void>;
}

/** Согласует сессию, библиотеку и действия фич; создаётся на время жизни приложения. */
export class Application {
  capabilities = $state<Capabilities>({
    web_search: false,
    spotify_import: false,
  });

  readonly auth = new AuthState();
  readonly library = new PlaylistsState();
  readonly language = new LanguageState();
  readonly theme = new ThemeState();
  readonly settings = new SettingsState();

  uploadsTrackIds = $state.raw<Set<string> | null>(null);
  currentTrackAdding = $state<string | null>(null);
  private uploadsMembershipController?: AbortController;

  settingsOpen = $state(false);

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
  /** Версия запрещает ответам прежней сессии изменять актуальное состояние. */
  private sessionVersion = 0;

  /** Разрешает скачивание, если сервер включил хотя бы одну интеграцию. */
  get importsEnabled(): boolean {
    return this.capabilities.web_search || this.capabilities.spotify_import;
  }

  /** Обновляет состав Uploads; отменяет предыдущий запрос и игнорирует старую сессию. */
  async syncUploadsMembership(): Promise<void> {
    const user = this.auth.user;
    if (!user) return;

    const version = this.sessionVersion;
    this.uploadsMembershipController?.abort();
    const controller = (this.uploadsMembershipController = new AbortController());

    try {
      const playlist =
        this.library.selected?.id === user.default_playlist_id
          ? this.library.selected
          : await playlistsApi.playlist(user.default_playlist_id, controller.signal);
      if (controller.signal.aborted || version !== this.sessionVersion) return;

      this.uploadsTrackIds = new Set(playlist.tracks.map((track) => track.id));
    } catch (error) {
      if (!controller.signal.aborted && version === this.sessionVersion)
        this.notify(errorMessage(error));
    }
  }

  /** Переключает наличие текущего трека в Uploads; удаление собственного требует подтверждения. */
  async toggleCurrentUploads(): Promise<void> {
    const track = this.player.value.current;
    const user = this.auth.user;
    if (!track || !user || !this.uploadsTrackIds || this.currentTrackAdding) return;

    const version = this.sessionVersion;
    const remove = async (): Promise<void> => {
      this.currentTrackAdding = track.id;

      try {
        await tracksApi.removeTrack(track.id);
        if (version !== this.sessionVersion) return;

        const ids = new Set(this.uploadsTrackIds ?? []);
        ids.delete(track.id);
        this.uploadsTrackIds = ids;
        delete this.search.serviceAdditions[track.id];
        if (this.search.web.playingTrackId === track.id && this.search.web.playingTrackKey)
          delete this.search.web.additions[this.search.web.playingTrackKey];
        if (track.owner_id === user.id) this.player.engine.remove(track.id);
        await this.refresh();
      } finally {
        if (version === this.sessionVersion) this.currentTrackAdding = null;
      }
    };
    if (this.uploadsTrackIds.has(track.id)) {
      if (track.owner_id === user.id) {
        this.confirmation = {
          title: this.language.t('tracks.deleteTitle'),
          description: this.language.t('tracks.deleteDescription', { title: track.title }),
          remove,
        };
      } else await remove();
      return;
    }
    this.currentTrackAdding = track.id;

    try {
      await this.addServiceTrack(track);
    } finally {
      if (version === this.sessionVersion) this.currentTrackAdding = null;
    }
  }

  /** Открывает настройки и закрывает панели, мешающие их просмотру. */
  openSettings(): void {
    this.settingsOpen = true;
    this.player.lyricsOpen = false;
    this.libraryOpen = false;
    this.search.close();
    this.menu.close();
  }

  /** Показывает сообщение на шесть секунд, заменяя предыдущее. */
  notify(message: string): void {
    clearTimeout(this.toastTimer);
    this.toast = message;
    this.toastTimer = setTimeout(() => {
      this.toast = '';
    }, 6000);
  }

  /** Передаёт ошибку фоновой операции в уведомление, пока приложение активно. */
  run(task: Promise<unknown>): void {
    void task.catch((error) => {
      if (!this.disposed) this.notify(errorMessage(error));
    });
  }

  /** Проверяет сессию и открывает форму входа при её отсутствии. */
  requireLogin(): boolean {
    if (this.auth.user) return true;

    this.authOpen = true;

    return false;
  }

  /** Создаёт сессию и загружает библиотеку, предварительно сбрасывая прежнее состояние. */
  async signIn(username: string, password: string, register: boolean): Promise<void> {
    // Инвалидируем прежние запросы до замены cookie сессии.
    this.reset();
    this.authOpen = true;
    await authApi.signIn(username, password, register);
    await this.openSession();
    await this.syncUploadsMembership();
  }

  /** Восстанавливает сессию или доступ по ссылке и обрабатывает ошибки входа. */
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

  /** Загружает возможности сервера, пользователя и выбранный плейлист для текущей версии сессии. */
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

  /** Восстанавливает сессию и состояние кнопки добавления в Uploads. */
  async start(): Promise<void> {
    await this.openSession();
    await this.syncUploadsMembership();
  }

  /** Выбирает плейлист, обновляет URL и метаданные плеера без перезапуска трека. */
  async selectPlaylist(
    id: string,
    token: string | null = null,
    showPlaylist = true,
  ): Promise<void> {
    if (showPlaylist) {
      this.settingsOpen = false;
      this.search.close();
    }
    this.menu.close(false);
    this.libraryOpen = false;
    if (await this.library.select(id, token)) {
      const selected = this.library.selected!;
      if (selected.id === this.auth.user?.default_playlist_id)
        this.uploadsTrackIds = new Set(selected.tracks.map((track) => track.id));
      this.player.engine.updateMetadata(selected.tracks);
      selectNavigation(selected.id, token);
      if (this.player.cover?.id === selected.id) this.player.cover = selected;
    }
    this.libraryOpen = false;
  }

  /** Обновляет библиотеку, сохраняя выбранный плейлист и доступ по ссылке. */
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
    await this.syncUploadsMembership();
  }

  /** Открывает плейлист локального результата и запускает найденный трек. */
  async playSearchResult(result: LocalResult, keepOpen = false): Promise<void> {
    this.search.remember({ kind: 'local', result });
    await this.selectPlaylist(result.playlistId, null, !keepOpen);
    this.settingsOpen = false;
    if (this.library.selected?.id !== result.playlistId) return;

    const track = this.library.selected?.tracks.find((item) => item.id === result.track.id);
    if (track) this.play(track);
  }

  /** Запускает трек в очереди плейлиста либо переключает паузу у текущего. */
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

  /** Добавляет каталожный трек в Uploads и при необходимости в другой плейлист. */
  async addWebTrack(track: SearchTrack, playlistId?: string): Promise<void> {
    if (!this.importsEnabled) return;

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

  /** Готовит каталожный трек и воспроизводит его без добавления в Uploads. */
  async playWebTrack(track: SearchTrack): Promise<void> {
    if (!this.importsEnabled) return;

    const user = this.auth.user;
    if (!this.requireLogin() || !user) return;

    this.search.remember({ kind: 'web', track });
    const key = searchTrackKey(track);
    if (
      this.search.web.playingTrackKey === key &&
      this.search.web.playingTrackId === this.player.value.current?.id &&
      this.player.engine.audio.src
    ) {
      this.player.engine.toggle();
      return;
    }
    this.search.web.playingTrackKey = key;
    this.search.web.playingTrackId = null;
    await this.player.engine.loadDeferred(async (signal) => {
      const id = await this.search.web.prepare(track, signal);
      signal.throwIfAborted();
      this.search.web.playingTrackId = id;

      return waitForDownloadedTrack(id, signal);
    });
  }

  /** Воспроизводит загруженный общий трек либо переключает его паузу. */
  async playServiceTrack(track: Track): Promise<void> {
    if (!this.requireLogin()) return;

    this.search.remember({ kind: 'service', track });
    if (this.player.value.current?.id === track.id && this.player.engine.audio.src) {
      this.player.engine.toggle();
      return;
    }
    this.player.cover = null;
    await this.player.engine.load(track, [track], true);
  }

  /** Привязывает общий трек к плейлисту; предотвращает одновременное добавление в Uploads. */
  async addServiceTrack(track: Track, playlistId?: string): Promise<void> {
    const user = this.auth.user;
    if (!this.requireLogin() || !user) return;

    const target = playlistId ?? user.default_playlist_id;
    const addingToUploads = target === user.default_playlist_id;
    if (
      addingToUploads &&
      (this.uploadsTrackIds?.has(track.id) || this.search.serviceAdditions[track.id] === 'adding')
    )
      return;

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

  /** Переключает меню загруженного общего трека у указанной кнопки. */
  showServiceTrackMenu(track: Track, origin: HTMLElement): void {
    this.menu.toggle(serviceTrackMenu(this, track), origin);
  }

  /** Переключает меню каталожного результата у указанной кнопки. */
  showWebTrackMenu(track: SearchTrack, origin: HTMLElement): void {
    this.menu.toggle(webTrackMenu(this, track), origin);
  }

  /** Включает случайный порядок и запускает доступный трек выбранного плейлиста. */
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

  /** Открывает меню трека по ПКМ либо переключает его у кнопки действий. */
  showTrackMenu(track: Track, origin: HTMLElement, point?: { x: number; y: number }): void {
    const items = trackMenu(this, track);
    if (point) this.menu.open(items, origin, point);
    else this.menu.toggle(items, origin);
  }

  /** Открывает меню плейлиста в координатах контекстного клика. */
  showPlaylistMenu(
    playlist: PlaylistSummary,
    origin: HTMLElement,
    point: { x: number; y: number },
  ): void {
    this.menu.open(playlistMenu(this, playlist), origin, point);
  }

  /** Открывает создание плейлиста после проверки входа. */
  createPlaylist(): void {
    if (this.requireLogin()) {
      this.libraryOpen = false;
      this.run(this.editor.edit());
    }
  }

  /** Открывает загрузку файлов после проверки входа. */
  upload(): void {
    if (this.requireLogin()) {
      this.libraryOpen = false;
      this.uploads.open = true;
    }
  }

  /** Открывает импорт Spotify, если интеграция доступна и пользователь вошёл. */
  importSpotify(): void {
    if (!this.capabilities.spotify_import) return;

    if (this.requireLogin()) {
      this.libraryOpen = false;
      this.uploads.open = false;
      this.spotify.open = true;
    }
  }

  /** Завершает сессию и перезагружает приложение; блокируется во время загрузки файлов. */
  async logout(): Promise<void> {
    if (this.uploads.busy) {
      this.notify(this.language.t('app.finishOrCancelUploads'));
      return;
    }
    await authApi.logout();
    this.reset();
    location.reload();
  }

  /** Выполняет подтверждённое удаление, защищая от повторного нажатия. */
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

  /** Обновляет обработку треков в активной сессии без пересечения циклов опроса. */
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

  /** Сбрасывает данные сессии и инвалидирует незавершённые операции. */
  reset(): void {
    this.uploadsMembershipController?.abort();
    this.uploadsTrackIds = null;
    this.currentTrackAdding = null;
    this.settingsOpen = false;
    this.sessionVersion++;
    clearTimeout(this.toastTimer);
    this.toast = '';
    this.sessionLoading = false;
    this.sessionError = '';
    this.player.engine.stop();
    this.player.lyricsOpen = false;
    this.uploads.reset();
    this.spotify.reset();
    this.search.reset();
    this.editor.reset();
    this.auth.reset();
    this.library.reset();
    this.menu.close(false);
  }

  /** Освобождает плеер, запросы и таймер уведомления при завершении приложения. */
  dispose(): void {
    this.uploadsMembershipController?.abort();
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
