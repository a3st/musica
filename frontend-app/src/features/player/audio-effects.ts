import { audioSettings, frequencies, type AudioSettings } from '../settings/model';

/** Владеет аудиографом Web Audio; HTMLAudioElement остаётся ресурсом плеера. */
export class AudioEffects {
  private context?: AudioContext;
  private filters: BiquadFilterNode[] = [];
  private headroom?: GainNode;
  private normalizer?: AudioWorkletNode;
  private settings = audioSettings(null);
  private disposed = false;

  /** Сохраняет аудиоэлемент; граф создаётся позднее при пользовательском жесте. */
  constructor(private readonly audio: HTMLAudioElement) {}

  /** Лениво создаёт аудиограф при пользовательском жесте и возобновляет AudioContext. */
  activate(): void {
    if (this.disposed || typeof AudioContext === 'undefined') return;

    if (!this.context) {
      const context = (this.context = new AudioContext());
      const source = context.createMediaElementSource(this.audio);
      this.headroom = context.createGain();
      source.connect(this.headroom);
      let tail: AudioNode = this.headroom;
      this.filters = frequencies.map((frequency) => {
        const filter = context.createBiquadFilter();
        filter.type = 'peaking';
        filter.frequency.value = frequency;
        filter.Q.value = 0.7;
        tail.connect(filter);
        tail = filter;

        return filter;
      });
      tail.connect(context.destination);
      this.update(this.settings);
      if (context.audioWorklet)
        void context.audioWorklet
          .addModule('/audio/normalizer.js')
          .then(() => {
            if (this.disposed) return;

            this.normalizer = new AudioWorkletNode(context, 'musica-normalizer');
            tail.disconnect();
            tail.connect(this.normalizer);
            this.normalizer.connect(context.destination);
            this.volumeChanged();
          })
          .catch((error) => console.warn('Audio normalization unavailable', error));
    }
    if (this.context.state === 'suspended') void this.context.resume().catch(() => {});
  }

  /** Плавно меняет усиление полос и запас громкости для защиты от перегрузки. */
  update(settings: AudioSettings): void {
    this.settings = settings;
    const now = this.context?.currentTime ?? 0;
    this.filters.forEach((filter, index) =>
      filter.gain.setTargetAtTime(settings.gains[index], now, 0.02),
    );
    this.headroom?.gain.setTargetAtTime(10 ** (-Math.max(0, ...settings.gains) / 20), now, 0.02);
    this.volumeChanged();
  }

  /** Передаёт нормализатору уровень громкости и настройку включения. */
  volumeChanged(): void {
    this.normalizer?.port.postMessage({
      enabled: this.settings.normalization,
      volume: this.audio.volume,
    });
  }

  /** Сбрасывает накопленный уровень нормализатора перед новым треком. */
  resetTrack(): void {
    this.normalizer?.port.postMessage({ reset: true });
  }

  /** Закрывает порт нормализатора, отключает узлы и освобождает AudioContext. */
  dispose(): void {
    this.disposed = true;
    this.normalizer?.port.close();
    this.filters.forEach((filter) => filter.disconnect());
    this.headroom?.disconnect();
    this.normalizer?.disconnect();
    void this.context?.close().catch(() => {});
  }
}
