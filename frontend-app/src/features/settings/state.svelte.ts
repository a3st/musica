import { readPreference, writePreference } from '../../shared/utils/storage';
import { audioSettings, presets, type Preset } from './model';

export class SettingsState {
  audio = $state.raw(audioSettings(null));

  /** Восстанавливает проверенные аудионастройки, игнорируя повреждённую запись. */
  constructor() {
    try {
      this.audio = audioSettings(JSON.parse(readPreference('musica:audio-settings') ?? 'null'));
    } catch {
      /* Ignore invalid preferences. */
    }
  }

  /** Применяет профиль эквалайзера, сохраняя отдельный пользовательский вариант. */
  profile(preset: Preset): void {
    this.audio = {
      ...this.audio,
      preset,
      gains: [...(preset === 'custom' ? this.audio.custom : presets[preset])],
    };
    this.save();
  }

  /** Меняет усиление полосы в пределах ±12 дБ и выбирает пользовательский профиль. */
  band(index: number, gain: number): void {
    if (
      !Number.isInteger(index) ||
      index < 0 ||
      index >= this.audio.gains.length ||
      !Number.isFinite(gain)
    )
      return;

    const gains = [...this.audio.gains];
    gains[index] = Math.max(-12, Math.min(12, gain));
    this.audio = { ...this.audio, preset: 'custom', gains, custom: [...gains] };
    this.save();
  }

  /** Включает или выключает нормализацию и сохраняет настройку. */
  normalize(enabled: boolean): void {
    this.audio = { ...this.audio, normalization: enabled };
    this.save();
  }

  /** Сохраняет аудионастройки локально без обращения к серверу. */
  private save(): void {
    writePreference('musica:audio-settings', JSON.stringify(this.audio));
  }
}
