<script lang="ts">
  import Icon from '../../../shared/ui/Icon.svelte';
  import CollectionScrollbar from '../../../shared/ui/CollectionScrollbar.svelte';
  import TrackArtwork from '../../tracks/ui/TrackArtwork.svelte';
  import type { PlayerState } from '../state.svelte';
  import type { LanguageState } from '../../../shared/i18n/state.svelte';
  import type { Track } from '../../tracks/model';
  let { state: controller, language }: { state: PlayerState; language: LanguageState } = $props();
  let list = $state<HTMLDivElement>();
</script>

{#snippet row(track: Track, current = false)}
  <div class="queue-item" class:queue-current={current}>
    <button
      class="queue-track"
      data-queue-play={track.id}
      onclick={() => controller.engine.playQueued(track.id)}
      ><TrackArtwork {track} shareToken={controller.shareToken(track.id)} /><span
        ><strong>{track.title}</strong><small>{track.artist}</small></span
      ></button
    >{#if !current}<button
        class="icon-button"
        data-queue-remove={track.id}
        aria-label={language.t('queue.remove')}
        onclick={() => controller.engine.removeQueued(track.id)}><Icon name="close" /></button
      >{/if}
  </div>
{/snippet}
<aside
  id="queue-panel"
  class="queue-panel"
  class:open={controller.queueOpen}
  aria-label={language.t('queue.title')}
  inert={!controller.queueOpen}
>
  <div class="dialog-heading">
    <h2>{language.t('queue.title')}</h2>
    <button
      id="queue-close"
      class="icon-button"
      aria-label={language.t('common.close')}
      onclick={() => {
        controller.queueOpen = false;
      }}><Icon name="close" /></button
    >
  </div>
  <div id="queue-list" bind:this={list}>
    {#if controller.value.current}<h3>{language.t('queue.nowPlaying')}</h3>
      {@render row(controller.value.current, true)}
      <h3>{language.t('queue.upNext')}</h3>
      {#each controller.value.upcoming as track (track.id)}{@render row(track)}{:else}<p
          class="muted"
        >
          {language.t('queue.empty')}
        </p>{/each}{:else}<p class="muted">
        {language.t('queue.emptyHint')}
      </p>{/if}
  </div>
  <CollectionScrollbar target={list} label={language.t('queue.title')} contained />
</aside>
