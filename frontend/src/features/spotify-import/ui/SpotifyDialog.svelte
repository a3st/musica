<script lang="ts">
  import Dialog from '../../../shared/ui/Dialog.svelte';
  import Icon from '../../../shared/ui/Icon.svelte';
  import './SpotifyDialog.css';
  import type { SpotifyState } from '../state.svelte';
  import type { LanguageState } from '../../../shared/i18n/state.svelte';
  let { state: controller, language }: { state: SpotifyState; language: LanguageState } = $props();
  let input: HTMLInputElement;
  let dragging = $state(false);
  let selected = $state(0);
  const groups = $derived([
    ...(controller.input?.playlists ?? []),
    ...(controller.input?.library.length
      ? [
          {
            title: language.t('spotify.likedSongs'),
            tracks: controller.input.library,
          },
        ]
      : []),
  ]);
  const active = $derived(groups[selected] ?? groups[0]);
  $effect(() => {
    controller.input;
    selected = 0;
  });
  const summary = $derived(
    controller.readingFiles
      ? language.t('spotify.reading')
      : controller.preview && controller.input
        ? language.t('spotify.preview', {
            tracks: controller.preview.tracks,
            playlists: controller.input.playlists.length,
            skipped: controller.preview.skipped
              ? language.t('spotify.skipped', { count: controller.preview.skipped })
              : '',
          })
        : '',
  );
</script>

<Dialog id="spotify-dialog" bind:open={controller.open}>
  <div class="dialog-heading">
    <h2>{language.t('spotify.title')}</h2>
    <button
      class="icon-button"
      data-close
      aria-label={language.t('common.close')}
      onclick={() => {
        controller.open = false;
      }}><Icon name="close" /></button
    >
  </div>
  <p class="muted">
    {language.t('spotify.description')}
  </p>
  <form
    id="spotify-form"
    onsubmit={(event) => {
      event.preventDefault();
      void controller.start();
    }}
  >
    <div
      class="spotify-drop"
      class:dragging
      role="button"
      tabindex={controller.busy ? -1 : 0}
      aria-label={language.t('spotify.files')}
      aria-disabled={controller.busy || controller.readingFiles}
      onclick={(event) => {
        if (!controller.busy && !controller.readingFiles && event.target !== input) input.click();
      }}
      onkeydown={(event) => {
        if (
          (event.key === 'Enter' || event.key === ' ') &&
          !controller.busy &&
          !controller.readingFiles
        ) {
          event.preventDefault();
          input.click();
        }
      }}
      ondragover={(event) => {
        event.preventDefault();
        dragging = !controller.busy && !controller.readingFiles;
      }}
      ondragleave={() => {
        dragging = false;
      }}
      ondrop={(event) => {
        event.preventDefault();
        dragging = false;
        if (!controller.busy && !controller.readingFiles)
          void controller.read(Array.from(event.dataTransfer?.files ?? []));
      }}
    >
      <Icon name="upload" />
      <strong>{language.t('spotify.files')}</strong>
      <span>{language.t('spotify.dropHint')}</span>
      <input
        bind:this={input}
        id="spotify-files"
        type="file"
        accept="application/json,.json"
        multiple
        hidden
        disabled={controller.busy || controller.readingFiles}
        onchange={(event) => {
          void controller.read(Array.from(event.currentTarget.files ?? []));
          event.currentTarget.value = '';
        }}
      />
    </div>
    {#if active}
      <div class="spotify-preview">
        <div class="spotify-playlists" role="group" aria-label={language.t('playlists.label')}>
          {#each groups as group, index (index)}
            <button
              type="button"
              class:active={selected === index}
              aria-pressed={selected === index}
              onclick={() => {
                selected = index;
              }}
            >
              <strong>{group.title}</strong>
              <span>{language.t('playlists.trackCount', { count: group.tracks.length })}</span>
            </button>
          {/each}
        </div>
        <div
          class="spotify-tracks"
          aria-label={language.t('spotify.contents', { title: active.title })}
        >
          <h3>{active.title}</h3>
          <ul>
            {#each active.tracks as track, index (index)}
              <li><strong>{track.title}</strong><span>{track.artist}</span></li>
            {/each}
          </ul>
        </div>
      </div>
    {/if}
    <p class="muted">
      {language.t('spotify.searchHint')}
    </p>
    <p id="spotify-error" class="form-error" role="alert">{controller.error}</p>
    <button
      id="spotify-start"
      class="button primary wide"
      disabled={!controller.input || controller.busy}
      >{language.t('spotify.submit')}<Icon name="arrow" /></button
    >
  </form>
  <p id="spotify-summary" aria-live="polite">{summary}</p>
  <p id="spotify-progress" aria-live="polite">{controller.notice}</p>
</Dialog>
