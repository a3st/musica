<script lang="ts">
  import { frequencies } from '../model';
  import type { SettingsState } from '../state.svelte';

  let { settings, label }: { settings: SettingsState; label: string } = $props();
  const points = $derived(
    settings.audio.gains.map((gain, index) => `${80 + index * 110},${120 - gain * 8}`).join(' '),
  );
</script>

<div class="equalizer" role="group" aria-label={label}>
  <span class="gain maximum">+12dB</span>
  <span class="gain minimum">−12dB</span>
  <div class="equalizer-plot">
    <svg viewBox="0 0 710 240" preserveAspectRatio="none" aria-hidden="true">
      <defs
        ><linearGradient id="equalizer-fill" x1="0" y1="0" x2="0" y2="1"
          ><stop offset="0%" stop-color="currentColor" stop-opacity="0.38" /><stop
            offset="100%"
            stop-color="currentColor"
            stop-opacity="0"
          /></linearGradient
        ></defs
      >
      {#each frequencies as _, index}<line
          x1={80 + index * 110}
          x2={80 + index * 110}
          y1="20"
          y2="220"
          class="grid-line"
        />{/each}
      <line x1="25" x2="685" y1="120" y2="120" class="grid-line" />
      <polygon points={`80,220 ${points} 630,220`} fill="url(#equalizer-fill)" />
      <polyline {points} fill="none" stroke="currentColor" stroke-width="3" />
    </svg>
    <div class="equalizer-points" aria-hidden="true">
      {#each settings.audio.gains as gain, index}
        <i style={`left:${((80 + index * 110) / 710) * 100}%;top:${120 - gain * 8}px`}></i>
      {/each}
    </div>
    <div class="equalizer-controls">
      {#each frequencies as frequency, index}
        <label>
          <input
            type="range"
            min="-12"
            max="12"
            step="1"
            value={settings.audio.gains[index]}
            aria-label={`${frequency} Hz`}
            aria-valuetext={`${settings.audio.gains[index]} dB`}
            oninput={(event) => settings.band(index, event.currentTarget.valueAsNumber)}
          />
          <span>{frequency >= 1000 ? `${frequency / 1000}k` : frequency}Hz</span>
        </label>
      {/each}
    </div>
  </div>
</div>

<style>
  .equalizer {
    position: relative;
    padding: 32px 12px 24px 48px;
    border-radius: 8px;
    background: var(--surface);
    color: var(--text);
  }

  .equalizer-plot {
    position: relative;
    height: 240px;
  }

  svg {
    width: 100%;
    height: 240px;
  }

  .grid-line {
    stroke: var(--border);
    stroke-width: 1;
  }

  .equalizer-points {
    position: absolute;
    inset: 0;
    pointer-events: none;
  }

  .equalizer-points i {
    position: absolute;
    width: 9px;
    height: 9px;
    border-radius: 50%;
    background: var(--text);
    transform: translate(-50%, -50%);
  }

  .gain {
    position: absolute;
    left: 10px;
    font-size: 12px;
    font-weight: 600;
    color: var(--muted);
  }

  .maximum {
    top: 48px;
  }

  .minimum {
    bottom: 58px;
  }

  .equalizer-controls {
    position: absolute;
    inset: 19.5px 11.2676% 0;
    display: flex;
    justify-content: space-between;
  }

  label {
    display: flex;
    align-items: center;
    flex-direction: column;
    width: 0;
    gap: 20px;
    font-size: 12px;
    font-weight: 600;
    color: var(--muted);
  }

  .equalizer input[type='range'] {
    appearance: none;
    writing-mode: vertical-lr;
    direction: rtl;
    width: 24px;
    min-width: 24px;
    height: 201px;
    flex: none;
    padding: 0;
    margin: 0;
    border: 0;
    border-radius: 0;
    background: transparent;
    cursor: ns-resize;
  }

  .equalizer input[type='range']::-webkit-slider-runnable-track {
    width: 3px;
    background: transparent;
  }

  .equalizer input[type='range']::-webkit-slider-thumb {
    appearance: none;
    width: 9px;
    height: 9px;
    margin-left: -3px;
    border: 0;
    border-radius: 50%;
    background: var(--text);
    opacity: 0;
  }

  .equalizer input[type='range']::-moz-range-track {
    background: transparent;
  }

  .equalizer input[type='range']::-moz-range-thumb {
    width: 9px;
    height: 9px;
    border: 0;
    border-radius: 50%;
    background: var(--text);
    opacity: 0;
  }

  @media (max-width: 760px) {
    .equalizer {
      padding-left: 38px;
      padding-right: 0;
    }

    label,
    .gain {
      font-size: 9px;
    }
  }
</style>
