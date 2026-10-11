<script lang="ts">
  import Icon from '../../../shared/ui/Icon.svelte';
  import CoverArt from './CoverArt.svelte';
  import type { PlaylistsState } from '../state.svelte';
  import type { PlaylistSummary } from '../model';
  import type { LanguageState } from '../../../shared/i18n/state.svelte';
  let {
    state: controller,
    language,
    create,
    select,
    menu,
    scrolling = false,
    onscroll,
  }: {
    state: PlaylistsState;
    language: LanguageState;
    create: () => void;
    select: (id: string) => void;
    menu: (playlist: PlaylistSummary, origin: HTMLElement, point: { x: number; y: number }) => void;
    scrolling?: boolean;
    onscroll?: () => void;
  } = $props();
</script>

<div class="library-heading">
  <span>{language.t('playlists.label')}</span><button
    class="icon-button"
    data-action="new-playlist"
    aria-label={language.t('playlists.create')}
    onclick={create}><Icon name="plus" /></button
  >
</div>
<label class="playlist-search"
  ><Icon name="search" /><input
    class="playlist-search-input"
    type="search"
    placeholder={language.t('playlists.searchPlaceholder')}
    aria-label={language.t('playlists.search')}
    autocomplete="off"
    bind:value={controller.filter}
  /></label
>
<nav
  class="playlist-nav"
  class:scrolling
  aria-label={language.t('playlists.navigation')}
  {onscroll}
>
  {#each controller.visiblePlaylists as playlist (playlist.id)}
    <button
      class="playlist-link"
      class:active={controller.selected?.id === playlist.id}
      data-playlist={playlist.id}
      title={playlist.title}
      aria-label={playlist.title}
      aria-current={controller.selected?.id === playlist.id ? 'page' : undefined}
      onclick={() => select(playlist.id)}
      oncontextmenu={(event) => {
        event.preventDefault();
        menu(playlist, event.currentTarget, { x: event.clientX, y: event.clientY });
      }}
    >
      <span class="nav-cover"
        ><CoverArt
          playlist={controller.selected?.id === playlist.id ? controller.selected : playlist}
          mini
        /></span
      ><span
        ><strong>{playlist.title}</strong><small
          >{playlist.is_default
            ? language.t('playlists.allUploads')
            : playlist.role !== 'owner'
              ? language.t('playlists.shared')
              : language.t('playlists.trackCount', { count: playlist.track_count })}</small
        ></span
      >
    </button>
  {:else}
    <p class="nav-empty">
      {language.t(controller.filter ? 'playlists.noResults' : 'playlists.empty')}
    </p>
  {/each}
</nav>
