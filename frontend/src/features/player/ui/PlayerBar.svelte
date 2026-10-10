<script lang="ts">
  import Icon from '../../../shared/ui/Icon.svelte';
  import TrackArtwork from '../../tracks/ui/TrackArtwork.svelte';
  import { time } from '../../../shared/utils/time';
  import type { PlayerState } from '../state.svelte';
  import type { LanguageState } from '../../../shared/i18n/state.svelte';
  let { state: controller, language }: { state: PlayerState; language: LanguageState } = $props();
  const value = $derived(controller.value);
  const progress = $derived(value.duration ? (value.elapsed / value.duration) * 100 : 0);
  const volume = $derived(value.muted ? 0 : value.volume);
  const repeatLabel = $derived(
    language.t(
      value.repeat === 'one'
        ? 'player.repeatTrack'
        : value.repeat === 'all'
          ? 'player.repeatPlaylist'
          : 'player.repeatOff',
    ),
  );
  const muteLabel = $derived(language.t(value.muted ? 'player.unmute' : 'player.mute'));
</script>

<footer class="player">
  <div class="now-playing" hidden={!value.current && !value.loading} aria-live="polite">
    <div id="now-art" class="mini-cover empty-cover">
      {#if value.current}<TrackArtwork
          track={value.current}
          shareToken={controller.shareToken(value.current.id)}
          eager
        />{:else}<Icon name="music" />{/if}
    </div>
    <div class="now-text">
      <strong id="now-title">{value.current?.title ?? language.t('player.preparing')}</strong><span
        id="now-artist"
        >{value.loading ? language.t('player.preparing') : (value.current?.artist ?? '')}</span
      >
    </div>
  </div>
  <div class="player-center">
    <div class="transport">
      <button
        id="shuffle"
        class="icon-button"
        aria-label={language.t('player.shuffle')}
        title={language.t('player.shuffle')}
        aria-pressed={value.shuffle}
        onclick={() => controller.engine.toggleShuffle()}><Icon name="shuffle" /></button
      >
      <button
        id="player-previous"
        class="icon-button"
        aria-label={language.t('player.previous')}
        title={language.t('player.previous')}
        onclick={() => controller.engine.previous()}><Icon name="previous" /></button
      >
      <button
        id="player-play"
        class="icon-button play-button"
        aria-label={language.t(value.paused ? 'player.play' : 'player.pause')}
        disabled={!value.current || value.loading}
        onclick={() => controller.engine.toggle()}
        >{#if value.loading}<span class="spinner" aria-label={language.t('player.preparing')}
          ></span>{:else}<Icon name={value.paused ? 'play' : 'pause'} />{/if}</button
      >
      <button
        id="player-next"
        class="icon-button"
        aria-label={language.t('player.next')}
        title={language.t('player.next')}
        onclick={() => controller.engine.next()}><Icon name="next" /></button
      >
      <button
        id="repeat"
        class="icon-button"
        aria-label={repeatLabel}
        title={repeatLabel}
        aria-pressed={value.repeat !== 'none'}
        data-mode={value.repeat}
        onclick={() => controller.engine.cycleRepeat()}><Icon name="repeat" /></button
      >
    </div>
    <div class="timeline">
      <span id="elapsed">{time(value.elapsed)}</span><input
        id="player-seek"
        type="range"
        min="0"
        max="1000"
        value={progress * 10}
        style={`--progress:${progress}%`}
        aria-label={language.t('player.position')}
        aria-valuetext={language.t('player.elapsedOfTotal', {
          elapsed: time(value.elapsed),
          total: time(value.duration),
        })}
        disabled={!value.duration}
        oninput={(event) => controller.engine.seek(Number(event.currentTarget.value))}
      /><span id="duration">{time(value.duration)}</span>
    </div>
  </div>
  <div class="player-right">
    <button
      id="queue-toggle"
      class="icon-button"
      aria-label={language.t('queue.title')}
      title={language.t('queue.title')}
      aria-controls="queue-panel"
      aria-expanded={controller.queueOpen}
      onclick={() => {
        controller.queueOpen = !controller.queueOpen;
      }}><Icon name="queue" /></button
    ><button
      id="mute"
      class="icon-button"
      aria-label={muteLabel}
      title={muteLabel}
      aria-pressed={value.muted}
      onclick={() => controller.engine.mute()}
      ><Icon name={value.muted ? 'muted' : 'volume'} /></button
    ><input
      id="volume"
      type="range"
      min="0"
      max="100"
      value={volume}
      style={`--progress:${volume}%`}
      aria-label={language.t('player.volume')}
      oninput={(event) => controller.engine.volume(Number(event.currentTarget.value))}
    />
  </div>
</footer>
