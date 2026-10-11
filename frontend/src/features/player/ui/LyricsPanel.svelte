<script lang="ts">
  import Icon from '../../../shared/ui/Icon.svelte';
  import CollectionScrollbar from '../../../shared/ui/CollectionScrollbar.svelte';
  import type { PlayerState } from '../state.svelte';
  import type { LanguageState } from '../../../shared/i18n/state.svelte';

  let { state: controller, language }: { state: PlayerState; language: LanguageState } = $props();
  let content = $state<HTMLDivElement>();

  function close(): void {
    controller.lyricsOpen = false;
    document.querySelector<HTMLButtonElement>('#lyrics-toggle')?.focus();
  }
</script>

<section
  id="lyrics-panel"
  class="lyrics-panel"
  class:open={controller.lyricsOpen}
  aria-labelledby="lyrics-title"
  inert={!controller.lyricsOpen}
>
  <div class="lyrics-heading">
    <div>
      <h2 id="lyrics-title">{language.t('lyrics.title')}</h2>
      {#if controller.value.current}
        <p>{controller.value.current.title} · {controller.value.current.artist}</p>
      {/if}
    </div>
    <button
      class="icon-button"
      id="lyrics-close"
      aria-label={language.t('common.close')}
      onclick={close}><Icon name="close" /></button
    >
  </div>
  <div id="lyrics-content" class="lyrics-content" bind:this={content}>
    <div class="lyrics-empty" role="status">
      <Icon name="karaoke" />
      <p>{language.t('lyrics.unavailable')}</p>
    </div>
  </div>
  <CollectionScrollbar target={content} label={language.t('lyrics.title')} contained />
</section>
