export const frequencies = [60, 150, 400, 1000, 2400, 15000] as const;

export const presets = {
  flat: [0, 0, 0, 0, 0, 0],
  bass: [6, 4, 1, 0, -1, 0],
  vocal: [-2, -1, 2, 4, 3, 0],
  rock: [4, 2, -1, 1, 3, 4],
} as const;

export type Preset = keyof typeof presets | 'custom';

export interface AudioSettings {
  preset: Preset;
  gains: number[];
  custom: number[];
  normalization: boolean;
}

export function audioSettings(value: unknown): AudioSettings {
  const data = value && typeof value === 'object' ? (value as Partial<AudioSettings>) : {};
  const preset =
    data.preset === 'custom' || Object.hasOwn(presets, data.preset ?? '')
      ? (data.preset as Preset)
      : 'flat';
  const custom =
    Array.isArray(data.custom) &&
    data.custom.length === frequencies.length &&
    data.custom.every(
      (gain) => typeof gain === 'number' && Number.isFinite(gain) && Math.abs(gain) <= 12,
    )
      ? [...data.custom]
      : [...presets.flat];
  return {
    preset,
    custom,
    gains: preset === 'custom' ? [...custom] : [...presets[preset]],
    normalization: data.normalization === true,
  };
}
