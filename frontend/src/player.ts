import { t, msg } from './i18n';
import type Hls from 'hls.js';
import { api, errorMessage, type Track } from './api';
import { icon, time } from './icons';

export class Player {
  readonly audio = new Audio();
  current: Track | null = null;
  loading = false;
  private queue: Track[] = [];
  private hls: Hls | null = null;
  private generation = 0;
  private shuffle = false;
  private repeat: 'none' | 'all' | 'one' = 'none';
  private readonly play = document.querySelector<HTMLButtonElement>('#player-play')!;
  private readonly seek = document.querySelector<HTMLInputElement>('#player-seek')!;
  constructor(private readonly changed: () => void, private readonly notify: (message: string) => void, private readonly userId: () => string | null, private readonly shareToken: (id: string) => string | null = () => null) {
    this.audio.preload = 'metadata';
    this.play.onclick = () => this.toggle();
    document.querySelector<HTMLButtonElement>('#player-next')!.onclick = () => this.advance(1);
    document.querySelector<HTMLButtonElement>('#player-previous')!.onclick = () => { if (this.audio.currentTime > 3) this.audio.currentTime = 0; else this.advance(-1); };
    document.querySelector<HTMLButtonElement>('#shuffle')!.onclick = (e) => { this.shuffle = !this.shuffle; (e.currentTarget as HTMLButtonElement).setAttribute('aria-pressed', String(this.shuffle)); };
    document.querySelector<HTMLButtonElement>('#repeat')!.onclick = (e) => {
      this.repeat = this.repeat === 'none' ? 'all' : this.repeat === 'all' ? 'one' : 'none';
      const button = e.currentTarget as HTMLButtonElement;
      button.setAttribute('aria-pressed', String(this.repeat !== 'none')); button.dataset.mode = this.repeat;
      button.title = this.repeat === 'one' ? t('Повтор трека') : this.repeat === 'all' ? t('Повтор плейлиста') : t('Повтор выключен');
      button.setAttribute('aria-label', button.title);
    };
    this.seek.oninput = () => { if (Number.isFinite(this.audio.duration)) this.audio.currentTime = Number(this.seek.value) / 1000 * this.audio.duration; };
    document.querySelector<HTMLInputElement>('#volume')!.oninput = (e) => { const input = e.target as HTMLInputElement; this.audio.volume = Number(input.value) / 100; if (this.audio.volume > 0) this.audio.muted = false; this.syncVolume(); };
    document.querySelector<HTMLButtonElement>('#mute')!.onclick = () => { this.audio.muted = !(this.audio.muted || this.audio.volume === 0); if (!this.audio.muted && this.audio.volume === 0) this.audio.volume = 0.5; this.syncVolume(); };
    this.audio.addEventListener('volumechange', () => this.syncVolume());
    for (const event of ['play', 'pause', 'loadedmetadata', 'timeupdate', 'durationchange', 'emptied']) this.audio.addEventListener(event, () => this.sync());
    this.audio.addEventListener('ended', () => { if (this.repeat === 'one') { this.audio.currentTime = 0; this.resume(); } else this.advance(1, true); });
    this.audio.addEventListener('error', () => { if (this.current && !this.loading) this.notify(t('Не удалось воспроизвести трек. Проверьте соединение.')); });
    document.addEventListener('keydown', (e) => { if (e.code === 'Space' && e.target instanceof HTMLElement && !e.target.closest('input,textarea,select,button,[contenteditable],dialog')) { e.preventDefault(); this.toggle(); } });
    if ('mediaSession' in navigator) {
      for (const [action, handler] of Object.entries({ play: () => this.resume(), pause: () => this.audio.pause(), previoustrack: () => this.advance(-1), nexttrack: () => this.advance(1) })) {
        try { navigator.mediaSession.setActionHandler(action as MediaSessionAction, handler); } catch { /* Unsupported system control. */ }
      }
    }
    this.sync();
    this.syncVolume();
    window.addEventListener('localechange', () => { this.sync(); this.syncVolume(); });
  }
  async load(track: Track, queue: Track[]): Promise<void> {
    this.stop(); const generation = this.generation;
    const token = this.shareToken(track.id);
    this.current = track; this.queue = queue.filter((item) => item.status !== 'pending'); this.loading = true;
    this.changed(); this.sync();
    try {
      if (track.status === 'pending') throw new Error(t('Сначала завершите загрузку файла'));
      if (track.status !== 'streamed') {
        if (track.owner_id === this.userId()) await api.prepare(track.id);
        for (let attempt = 0; ; attempt++) {
          if (generation !== this.generation) return;
          const state = await api.preparation(track.id, token);
          if (state.status === 'streamed') break;
          if (state.preparation === null && track.owner_id !== this.userId()) throw new Error(t('Владелец ещё не подготовил этот трек для прослушивания.'));
          if (state.preparation === 'failed') throw new Error(t('Не удалось подготовить файл. Выберите трек ещё раз для новой попытки.'));
          if (attempt >= 900) throw new Error(t('Подготовка продолжается. Попробуйте воспроизвести трек позже.'));
          await new Promise<void>((resolve) => setTimeout(resolve, 1000));
        }
      }
      if (generation !== this.generation) return;
      const url = `/api/tracks/${track.id}/hls/index.m3u8${token ? '?share_token=' + encodeURIComponent(token) : ''}`;
      this.current = { ...track, status: 'streamed' };
      if (this.audio.canPlayType('application/vnd.apple.mpegurl')) { this.audio.src = url; this.loading = false; this.resume(); }
      else {
        const { default: Hls } = await import('hls.js');
        if (generation !== this.generation) return;
        if (!Hls.isSupported()) throw new Error(t('Этот браузер не поддерживает HLS-воспроизведение'));
        const hls = new Hls({ xhrSetup: (xhr) => { xhr.withCredentials = true; }, enableWorker: true }); this.hls = hls;
        hls.on(Hls.Events.MANIFEST_PARSED, () => { if (generation === this.generation) { this.loading = false; this.sync(); this.changed(); this.resume(); } });
        hls.on(Hls.Events.ERROR, (_event, data) => { if (data.fatal && generation === this.generation) { this.loading = false; hls.destroy(); this.hls = null; this.audio.removeAttribute('src'); this.sync(); this.notify(t('Воспроизведение прервано. Выберите трек ещё раз.')); } });
        hls.loadSource(url); hls.attachMedia(this.audio);
      }
      if ('mediaSession' in navigator) navigator.mediaSession.metadata = new MediaMetadata({ title: track.title, artist: track.artist });
      this.changed(); this.sync();
    } catch (error) { if (generation === this.generation) { this.loading = false; this.notify(errorMessage(error)); this.sync(); this.changed(); } }
  }
  toggle(): void { if (!this.current || this.loading) return; if (this.audio.paused) this.resume(); else this.audio.pause(); }
  get upcoming(): readonly Track[] { const index = this.queue.findIndex((track) => track.id === this.current?.id); return this.queue.slice(index + 1); }
  enqueue(track: Track, next = false): void {
    if (track.status === 'pending') return;
    if (!this.current) { void this.load(track, [track]); return; }
    if (track.id === this.current.id) return;
    this.queue = this.queue.filter((item) => item.id !== track.id);
    if (next) this.queue.splice(this.queue.findIndex((item) => item.id === this.current!.id) + 1, 0, track);
    else this.queue.push(track);
    this.changed();
  }
  playQueued(id: string): void { const track = this.queue.find((item) => item.id === id); if (track) void this.load(track, this.queue); }
  removeQueued(id: string): void { if (id !== this.current?.id) this.queue = this.queue.filter((item) => item.id !== id); this.changed(); }
  private syncVolume(): void {
    const muted = this.audio.muted || this.audio.volume === 0;
    const button = document.querySelector<HTMLButtonElement>('#mute')!;
    button.innerHTML = icon(muted ? 'muted' : 'volume'); button.setAttribute('aria-pressed', String(muted));
    button.title = muted ? t('Включить звук') : t('Выключить звук'); button.setAttribute('aria-label', button.title);
    const input = document.querySelector<HTMLInputElement>('#volume')!;
    input.value = String(Math.round(this.audio.volume * 100)); input.style.setProperty('--progress', `${muted ? 0 : input.value}%`);
  }
  private resume(): void { if (!this.current || this.loading) return; if (this.audio.ended) this.audio.currentTime = 0; void this.audio.play().catch(() => this.notify(t('Нажмите «Воспроизвести», чтобы начать слушать'))); }
  private advance(direction: number, ended = false): void {
    if (!this.current || !this.queue.length) return;
    let index = this.queue.findIndex((item) => item.id === this.current!.id) + direction;
    if (this.shuffle && this.queue.length > 1 && direction > 0) {
      const candidates = this.queue.filter((item) => item.id !== this.current!.id);
      const picked = candidates[Math.floor(Math.random() * candidates.length)]; index = this.queue.findIndex((item) => item.id === picked.id);
    }
    if (ended && index >= this.queue.length && this.repeat === 'none') { this.sync(); return; }
    void this.load(this.queue[(index + this.queue.length) % this.queue.length], this.queue);
  }
  stop(): void { this.generation++; this.audio.pause(); this.hls?.destroy(); this.hls = null; this.audio.removeAttribute('src'); this.audio.load(); this.current = null; this.queue = []; this.loading = false; this.sync(); this.changed(); }
  remove(id: string): void { this.queue = this.queue.filter((track) => track.id !== id); if (this.current?.id === id) this.stop(); }
  private sync(): void {
    const repeat = document.querySelector<HTMLButtonElement>('#repeat')!;
    repeat.title = this.repeat === 'one' ? t('Повтор трека') : this.repeat === 'all' ? t('Повтор плейлиста') : t('Повтор выключен');
    repeat.setAttribute('aria-label', repeat.title);
    this.play.disabled = !this.current || this.loading; this.play.innerHTML = icon(this.audio.paused ? 'play' : 'pause');
    this.play.setAttribute('aria-label', this.audio.paused ? t('Воспроизвести') : t('Пауза'));
    const duration = Number.isFinite(this.audio.duration) ? this.audio.duration : 0;
    document.querySelector<HTMLElement>('#elapsed')!.textContent = time(this.audio.currentTime);
    document.querySelector<HTMLElement>('#duration')!.textContent = time(duration);
    this.seek.disabled = !duration; this.seek.value = String(duration ? this.audio.currentTime / duration * 1000 : 0);
    this.seek.style.setProperty('--progress', `${duration ? this.audio.currentTime / duration * 100 : 0}%`);
    this.seek.setAttribute('aria-valuetext', msg`${time(this.audio.currentTime)} из ${time(duration)}`);
  }
}
