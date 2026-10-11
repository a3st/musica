import { t } from '../../shared/i18n';
import { errorMessage } from '../../shared/api/errors';
import { readPreference, writePreference } from '../../shared/utils/storage';
import type Hls from 'hls.js';
import { tracksApi as api } from '../tracks/api';
import type { Track } from '../tracks/model';
export class PlayerEngine {
  readonly audio = new Audio();
  current: Track | null = null;
  loading = false;
  shuffle = false;
  repeat: 'none' | 'all' | 'one' = 'none';
  private queue: Track[] = [];
  private hls: Hls | null = null;
  private generation = 0;
  private playbackRequested = false;
  private playAttempt: Promise<void> | null = null;
  private deferredController?: AbortController;
  private readonly listeners = new AbortController();
  constructor(
    private readonly emit: () => void,
    private readonly notify: (message: string) => void,
    private readonly userId: () => string | null,
    private readonly shareToken: (id: string) => string | null,
  ) {
    this.audio.preload = 'metadata';
    const storedVolume = readPreference('musica:volume');
    const volume = storedVolume === null ? NaN : Number(storedVolume);
    if (storedVolume?.trim() && Number.isFinite(volume) && volume >= 0 && volume <= 100)
      this.audio.volume = volume / 100;
    this.audio.muted = readPreference('musica:muted') === 'true';

    this.audio.addEventListener('volumechange', () => this.saveVolume(), {
      signal: this.listeners.signal,
    });
    for (const event of [
      'play',
      'pause',
      'loadedmetadata',
      'timeupdate',
      'durationchange',
      'emptied',
      'volumechange',
    ])
      this.audio.addEventListener(event, () => this.emit(), { signal: this.listeners.signal });
    this.audio.addEventListener(
      'canplay',
      () => {
        if (this.playbackRequested && this.audio.paused) this.startPlayback();
      },
      { signal: this.listeners.signal },
    );
    this.audio.addEventListener(
      'ended',
      () => {
        if (this.repeat === 'one') {
          this.audio.currentTime = 0;
          this.resume();
        } else this.advance(1, true);
      },
      { signal: this.listeners.signal },
    );
    this.audio.addEventListener(
      'error',
      () => {
        if (this.current && !this.loading) this.notify(t('player.playFailed'));
      },
      { signal: this.listeners.signal },
    );
    if ('mediaSession' in navigator)
      for (const [action, handler] of Object.entries({
        play: () => this.resume(),
        pause: () => this.pause(),
        previoustrack: () => this.previous(),
        nexttrack: () => this.next(),
      })) {
        try {
          navigator.mediaSession.setActionHandler(action as MediaSessionAction, handler);
        } catch {
          /* Unsupported system control. */
        }
      }
  }
  snapshot() {
    return {
      current: this.current,
      loading: this.loading,
      upcoming: [...this.upcoming],
      paused: this.audio.paused,
      elapsed: this.audio.currentTime,
      duration: Number.isFinite(this.audio.duration) ? this.audio.duration : 0,
      volume: Math.round(this.audio.volume * 100),
      muted: this.audio.muted || this.audio.volume === 0,
      shuffle: this.shuffle,
      repeat: this.repeat,
    };
  }
  /** Обновляет данные текущего трека и очереди, сохраняя воспроизведение и порядок. */
  updateMetadata(tracks: Track[]): void {
    const updated = new Map(tracks.map((track) => [track.id, track]));
    if (this.current) this.current = updated.get(this.current.id) ?? this.current;
    this.queue = this.queue.map((track) => updated.get(track.id) ?? track);
    this.emit();
  }

  seek(value: number): void {
    if (Number.isFinite(this.audio.duration))
      this.audio.currentTime = (value / 1000) * this.audio.duration;
    this.emit();
  }
  volume(value: number): void {
    if (!Number.isFinite(value)) return;
    this.audio.volume = Math.max(0, Math.min(1, value / 100));
    if (this.audio.volume > 0) this.audio.muted = false;
    this.saveVolume();
    this.emit();
  }
  mute(): void {
    this.audio.muted = !(this.audio.muted || this.audio.volume === 0);
    if (!this.audio.muted && this.audio.volume === 0) this.audio.volume = 0.5;
    this.saveVolume();
    this.emit();
  }

  /** Сохраняет громкость отдельно от mute, чтобы выключение звука не теряло уровень. */
  private saveVolume(): void {
    writePreference('musica:volume', String(Math.round(this.audio.volume * 100)));
    writePreference('musica:muted', String(this.audio.muted));
  }
  toggleShuffle(): void {
    this.shuffle = !this.shuffle;
    this.emit();
  }
  cycleRepeat(): void {
    this.repeat = this.repeat === 'none' ? 'all' : this.repeat === 'all' ? 'one' : 'none';
    this.emit();
  }
  previous(): void {
    if (this.audio.currentTime > 3) this.audio.currentTime = 0;
    else this.advance(-1);
    this.emit();
  }
  next(): void {
    this.advance(1);
  }
  dispose(): void {
    this.listeners.abort();
    this.stop();
    if ('mediaSession' in navigator) {
      navigator.mediaSession.metadata = null;
      for (const action of ['play', 'pause', 'previoustrack', 'nexttrack'] as const) {
        try {
          navigator.mediaSession.setActionHandler(action, null);
        } catch {}
      }
    }
  }
  /** Ожидает загрузку каталожного трека, отменяя ожидание при выборе другого. */
  async loadDeferred(resolveTrack: (signal: AbortSignal) => Promise<Track>): Promise<void> {
    this.stop();
    const generation = this.generation;
    const controller = new AbortController();
    this.deferredController = controller;
    this.loading = true;
    this.emit();
    try {
      const track = await resolveTrack(controller.signal);
      if (generation !== this.generation || controller.signal.aborted) return;
      await this.load(track, [track], true);
    } catch (error) {
      if (generation === this.generation && !controller.signal.aborted) {
        this.loading = false;
        this.notify(errorMessage(error));
        this.emit();
      }
    }
  }

  async load(track: Track, queue: Track[], waitForAutomaticPreparation = false): Promise<void> {
    this.stop();
    const generation = this.generation;
    const token = this.shareToken(track.id);
    this.current = track;
    this.queue = queue.filter((item) => item.status !== 'pending');
    this.loading = true;
    this.playbackRequested = true;
    this.emit();
    try {
      if (track.status === 'pending') throw new Error(t('player.uploadRequired'));
      if (track.status !== 'streamed') {
        if (track.owner_id === this.userId()) await api.prepare(track.id);
        for (let attempt = 0; ; attempt++) {
          if (generation !== this.generation) return;
          const state = await api.preparation(track.id, token);
          if (state.status === 'streamed') break;
          if (
            state.preparation === null &&
            track.owner_id !== this.userId() &&
            !waitForAutomaticPreparation
          )
            throw new Error(t('player.ownerPreparationRequired'));
          if (state.preparation === 'failed') throw new Error(t('player.preparationFailed'));
          if (attempt >= 900) throw new Error(t('player.preparationTimeout'));
          await new Promise<void>((resolve) => setTimeout(resolve, 1000));
        }
      }
      if (generation !== this.generation) return;
      const url = `/api/tracks/${track.id}/hls/index.m3u8${token ? '?share_token=' + encodeURIComponent(token) : ''}`;
      this.current = { ...track, status: 'streamed' };
      if (this.audio.canPlayType('application/vnd.apple.mpegurl')) {
        this.audio.src = url;
        this.loading = false;
        this.resume();
      } else {
        const { default: Hls } = await import('hls.js');
        if (generation !== this.generation) return;
        if (!Hls.isSupported()) throw new Error(t('player.unsupported'));
        const hls = new Hls({
          xhrSetup: (xhr) => {
            xhr.withCredentials = true;
          },
          enableWorker: true,
        });
        this.hls = hls;
        hls.on(Hls.Events.MANIFEST_PARSED, () => {
          if (generation === this.generation) {
            this.loading = false;
            this.emit();
            this.startPlayback();
          }
        });
        hls.on(Hls.Events.ERROR, (_event, data) => {
          if (data.fatal && generation === this.generation) {
            this.playbackRequested = false;
            this.loading = false;
            hls.destroy();
            this.hls = null;
            this.audio.removeAttribute('src');
            this.emit();
            this.notify(t('player.interrupted'));
          }
        });
        hls.on(Hls.Events.MEDIA_ATTACHED, () => {
          if (generation !== this.generation) return;
          hls.loadSource(url);
          // Request playback once the media source exists; play() can wait for segments.
          this.startPlayback();
        });
        hls.attachMedia(this.audio);
      }
      if ('mediaSession' in navigator)
        navigator.mediaSession.metadata = new MediaMetadata({
          title: track.title,
          artist: track.artist,
        });
      this.emit();
    } catch (error) {
      if (generation === this.generation) {
        this.playbackRequested = false;
        this.loading = false;
        this.notify(errorMessage(error));
        this.emit();
      }
    }
  }
  toggle(): void {
    if (!this.current || this.loading) return;
    if (this.audio.paused) this.resume();
    else this.pause();
  }
  get upcoming(): readonly Track[] {
    const index = this.queue.findIndex((track) => track.id === this.current?.id);
    return this.queue.slice(index + 1);
  }
  enqueue(track: Track, next = false): void {
    if (track.status === 'pending') return;
    if (!this.current) {
      void this.load(track, [track]);
      return;
    }
    if (track.id === this.current.id) return;
    this.queue = this.queue.filter((item) => item.id !== track.id);
    if (next)
      this.queue.splice(this.queue.findIndex((item) => item.id === this.current!.id) + 1, 0, track);
    else this.queue.push(track);
    this.emit();
  }
  playQueued(id: string): void {
    const track = this.queue.find((item) => item.id === id);
    if (track) void this.load(track, this.queue);
  }
  removeQueued(id: string): void {
    if (id !== this.current?.id) this.queue = this.queue.filter((item) => item.id !== id);
    this.emit();
  }
  private resume(): void {
    if (!this.current || this.loading) return;
    this.playbackRequested = true;
    if (this.audio.ended) this.audio.currentTime = 0;
    this.startPlayback();
  }
  private pause(): void {
    this.playbackRequested = false;
    this.playAttempt = null;
    this.audio.pause();
  }
  private startPlayback(): void {
    if (!this.current || !this.playbackRequested || this.playAttempt) return;
    const generation = this.generation;
    const attempt = this.audio.play();
    this.playAttempt = attempt;
    void attempt
      .catch((error: unknown) => {
        if (generation !== this.generation || this.playAttempt !== attempt) return;
        // Source changes can interrupt play() before the first segment arrives.
        // Retry on canplay instead of asking for another click.
        if (error instanceof DOMException && error.name === 'AbortError') return;
        this.playbackRequested = false;
        this.notify(
          error instanceof DOMException && error.name === 'NotAllowedError'
            ? t('player.clickToPlay')
            : t('player.playFailed'),
        );
      })
      .finally(() => {
        if (this.playAttempt === attempt) this.playAttempt = null;
      });
  }
  private advance(direction: number, ended = false): void {
    if (!this.current || !this.queue.length) return;
    let index = this.queue.findIndex((item) => item.id === this.current!.id) + direction;
    if (this.shuffle && this.queue.length > 1 && direction > 0) {
      const candidates = this.queue.filter((item) => item.id !== this.current!.id);
      const picked = candidates[Math.floor(Math.random() * candidates.length)];
      index = this.queue.findIndex((item) => item.id === picked.id);
    }
    if (ended && index >= this.queue.length && this.repeat === 'none') {
      this.emit();
      return;
    }
    void this.load(this.queue[(index + this.queue.length) % this.queue.length], this.queue);
  }
  stop(): void {
    this.generation++;
    this.deferredController?.abort();
    this.deferredController = undefined;
    this.playbackRequested = false;
    this.playAttempt = null;
    this.audio.pause();
    this.hls?.destroy();
    this.hls = null;
    this.audio.removeAttribute('src');
    this.audio.load();
    this.current = null;
    this.queue = [];
    this.loading = false;
    this.emit();
  }
  remove(id: string): void {
    this.queue = this.queue.filter((track) => track.id !== id);
    if (this.current?.id === id) this.stop();
    else this.emit();
  }
}
