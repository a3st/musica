<script lang="ts">
  import CollectionScrollbar from '../../../shared/ui/CollectionScrollbar.svelte';
  import Dialog from '../../../shared/ui/Dialog.svelte';
  import Icon from '../../../shared/ui/Icon.svelte';
  import './SpotifyDialog.css';
  import type { SpotifyState } from '../state.svelte';
  import type { LanguageState } from '../../../shared/i18n/state.svelte';

  let { state: controller, language }: { state: SpotifyState; language: LanguageState } = $props();
  let playlistScroll = $state<HTMLDivElement>();
  let trackScroll = $state<HTMLDivElement>();
  let bodyScroll = $state<HTMLDivElement>();
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
  const activeKey = $derived(
    selected < (controller.input?.playlists.length ?? 0) ? `playlist:${selected}` : 'library',
  );

  $effect(() => {
    controller.input;
    selected = 0;
  });
</script>

<Dialog
  id="spotify-dialog"
  bind:open={controller.open}
  onclose={() => {
    controller.dismiss();
    dragging = false;
    input.value = '';
  }}
>
  <div class="spotify-body" bind:this={bodyScroll} id="spotify-body">
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
      {#if controller.readingFiles}<p class="muted" role="status">
          {language.t('spotify.reading')}
        </p>{/if}
      {#if active}
        <div class="spotify-preview">
          <div class="spotify-column">
            <div
              bind:this={playlistScroll}
              id="spotify-playlists-scroll"
              class="spotify-playlists"
              role="group"
              aria-label={language.t('playlists.label')}
            >
              {#each groups as group, index (index)}
                {@const key =
                  index < (controller.input?.playlists.length ?? 0)
                    ? `playlist:${index}`
                    : 'library'}
                <div class="spotify-playlist-row" class:excluded={controller.excluded.has(key)}>
                  <button
                    type="button"
                    class="spotify-group-select"
                    class:active={selected === index}
                    aria-pressed={selected === index}
                    onclick={() => {
                      selected = index;
                    }}
                  >
                    <strong>{group.title}</strong>
                    <span>{language.t('playlists.trackCount', { count: group.tracks.length })}</span
                    >
                  </button>
                  <button
                    type="button"
                    class="icon-button spotify-group-toggle"
                    disabled={controller.busy}
                    aria-pressed={!controller.excluded.has(key)}
                    aria-label={language.t(
                      controller.excluded.has(key)
                        ? 'spotify.includePlaylist'
                        : 'spotify.excludePlaylist',
                      { title: group.title },
                    )}
                    onclick={() => controller.toggle(key)}
                  >
                    <Icon name={controller.excluded.has(key) ? 'plus' : 'minus'} />
                  </button>
                </div>
              {/each}
            </div>
            <CollectionScrollbar
              contained
              target={playlistScroll}
              label={language.t('playlists.scroll')}
            />
          </div>
          <div class="spotify-column">
            <div
              bind:this={trackScroll}
              id="spotify-tracks-scroll"
              class="spotify-tracks"
              aria-label={language.t('spotify.contents', { title: active.title })}
            >
              <ul>
                {#each active.tracks as track, index (index)}
                  {@const key =
                    selected < (controller.input?.playlists.length ?? 0)
                      ? `playlist:${selected}:${index}`
                      : `library:${index}`}
                  <li
                    class:excluded={controller.excluded.has(activeKey) ||
                      controller.excluded.has(key)}
                  >
                    <div><strong>{track.title}</strong><span>{track.artist}</span></div>
                    <button
                      type="button"
                      class="icon-button"
                      disabled={controller.busy || controller.excluded.has(activeKey)}
                      aria-pressed={!controller.excluded.has(activeKey) &&
                        !controller.excluded.has(key)}
                      aria-label={language.t(
                        controller.excluded.has(key)
                          ? 'spotify.includeTrack'
                          : 'spotify.excludeTrack',
                        { title: track.title },
                      )}
                      onclick={() => controller.toggle(key)}
                      ><Icon name={controller.excluded.has(key) ? 'plus' : 'minus'} /></button
                    >
                  </li>
                {/each}
              </ul>
            </div>
            <CollectionScrollbar
              contained
              target={trackScroll}
              label={language.t('playlists.scroll')}
            />
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
        disabled={!controller.selectedTracks || controller.busy}
        >{language.t('spotify.submit')}<Icon name="arrow" /></button
      >
    </form>
    <p id="spotify-progress" aria-live="polite">{controller.notice}</p>
  </div>
  <CollectionScrollbar contained target={bodyScroll} label={language.t('playlists.scroll')} />
</Dialog>
