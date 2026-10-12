<script lang="ts">
  import Icon from '../../../shared/ui/Icon.svelte';
  import TrackArtwork from '../../tracks/ui/TrackArtwork.svelte';
  import CollectionScrollbar from '../../../shared/ui/CollectionScrollbar.svelte';
  import type { SearchState, LocalResult, RecentResult } from '../state.svelte';
  import type { SearchTrack } from '../../web-search/model';
  import type { Track } from '../../tracks/model';
  import { searchTrackKey } from '../../web-search/model';
  import type { LanguageState } from '../../../shared/i18n/state.svelte';
  import './SearchBox.css';

  let {
    state: controller,
    language,
    importsEnabled,
    play,
    add,
    playWeb,
    menu,
    playService,
    addService,
    serviceMenu,
    ownsContextMenu = false,
    currentId = null,
    paused = true,
    activeWebKey = null,
    waitingTrackKey = null,
    waitingServiceId = null,
  }: {
    state: SearchState;
    language: LanguageState;
    importsEnabled: boolean;
    play: (result: LocalResult, keepOpen: boolean) => void;
    add: (track: SearchTrack) => void;
    playWeb: (track: SearchTrack) => void;
    menu: (track: SearchTrack, origin: HTMLElement) => void;
    playService: (track: Track) => void;
    addService: (track: Track) => void;
    serviceMenu: (track: Track, origin: HTMLElement) => void;
    ownsContextMenu?: boolean;
    currentId?: string | null;
    paused?: boolean;
    activeWebKey?: string | null;
    waitingTrackKey?: string | null;
    waitingServiceId?: string | null;
  } = $props();
  let container: HTMLDivElement;
  let input: HTMLInputElement;
  let restoringFocus = false;
  let dropdown = $state<HTMLDivElement>();
  const results = $derived<RecentResult[]>(
    !controller.query.trim()
      ? controller.recent
      : controller.local.length
        ? controller.local.map((result) => ({ kind: 'local' as const, result }))
        : [
            ...controller.service.map((track) => ({ kind: 'service' as const, track })),
            ...controller.web.tracks.map((track) => ({ kind: 'web' as const, track })),
          ],
  );
  const error = $derived(controller.error || controller.web.error);

  /** Закрывает выдачу по внешнему клику, сохраняя её при работе с меню результата. */
  function closeOutside(event: MouseEvent): void {
    if (inContextMenu(event)) return;

    if (event.target instanceof Node && !container.contains(event.target)) controller.close();
  }

  /** Определяет события в контекстном меню, принадлежащем текущей выдаче. */
  function inContextMenu(event: Event): boolean {
    return (
      ownsContextMenu &&
      event
        .composedPath()
        .some(
          (element) =>
            element instanceof Element && element.matches('#context-menu, #context-submenu'),
        )
    );
  }

  /** Перемещает фокус между результатами и закрывает выдачу по Escape. */
  function keydown(event: KeyboardEvent): void {
    if (!(event.target instanceof Node) || !container.contains(event.target)) return;

    if (event.key === 'Escape' && controller.open) {
      event.preventDefault();
      event.stopPropagation();
      controller.close();
      restoringFocus = true;
      input.focus();
      restoringFocus = false;
    }
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;

    event.preventDefault();
    controller.open = true;
    const buttons = [
      ...container.querySelectorAll<HTMLButtonElement>('.search-result-action:not(:disabled)'),
    ];
    const current = buttons.indexOf(document.activeElement as HTMLButtonElement);
    const next = current + (event.key === 'ArrowDown' ? 1 : -1);
    if (next < 0 || next >= buttons.length) input.focus();
    else buttons[next].focus();
  }

  /** Передаёт воспроизведение нужному сценарию по виду результата. */
  function activate(result: RecentResult, keepOpen = false): void {
    if (result.kind === 'local') play(result.result, keepOpen);
    else if (result.kind === 'service') playService(result.track);
    else {
      controller.remember(result);
      playWeb(result.track);
    }
  }
</script>

<svelte:document
  onclick={closeOutside}
  onkeydown={keydown}
  onfocusin={(event) => {
    if (inContextMenu(event)) return;
    if (event.target instanceof Node && !container.contains(event.target)) controller.close();
  }}
/>
<div
  class="search-container"
  bind:this={container}
  role="group"
  aria-label={language.t('search.tracks')}
>
  <form
    class="search-shell"
    onsubmit={(event) => {
      event.preventDefault();
      void controller.search();
    }}
  >
    <label class="search">
      <Icon name="search" />
      <input
        bind:this={input}
        id="search"
        type="search"
        role="combobox"
        aria-haspopup="dialog"
        placeholder={language.t('search.placeholder')}
        aria-label={language.t('search.tracks')}
        aria-expanded={controller.open}
        aria-controls="search-results"
        aria-autocomplete="list"
        autocomplete="off"
        maxlength="256"
        value={controller.query}
        oninput={(event) => controller.setQuery(event.currentTarget.value)}
        onfocus={() => {
          if (restoringFocus) return;
          controller.open = true;
          if (controller.query.trim() && !controller.searched && !controller.loading)
            void controller.search();
        }}
      />
    </label>
    {#if controller.query}
      <button
        type="button"
        class="search-clear"
        aria-label={language.t('search.clear')}
        onclick={() => {
          controller.setQuery('');
          input.focus();
        }}><Icon name="close" /></button
      >
    {/if}
  </form>
  {#if controller.open}
    <div
      id="search-results"
      bind:this={dropdown}
      class="search-dropdown"
      role="dialog"
      tabindex="-1"
      aria-label={language.t('search.results')}
      aria-busy={controller.loading}
    >
      <h2>
        {language.t(
          !controller.query.trim()
            ? 'search.recent'
            : controller.local.length
              ? 'search.libraryResults'
              : 'search.results',
        )}
      </h2>
      {#if controller.loading}
        <p class="search-message" role="status">
          <span class="spinner"></span>{language.t('web.searching')}
        </p>
      {:else if error}
        <div class="search-message" role="alert">
          <span>{error}</span>
          <button class="button secondary" onclick={() => void controller.search()}
            >{language.t('common.retry')}</button
          >
        </div>
      {:else if results.length}
        <ul class="search-results-list">
          {#each results as result (result.kind === 'web' ? searchTrackKey(result.track) : result.kind === 'local' ? result.result.track.id : result.track.id)}
            {@const track = result.kind === 'local' ? result.result.track : result.track}
            {@const waiting =
              result.kind === 'web'
                ? waitingTrackKey === searchTrackKey(result.track)
                : result.kind === 'service' && waitingServiceId === result.track.id}
            {@const playing =
              !paused &&
              (result.kind === 'web'
                ? activeWebKey === searchTrackKey(result.track)
                : currentId ===
                  (result.kind === 'local' ? result.result.track.id : result.track.id))}
            <li class="search-result" data-source={result.kind}>
              <button
                class="search-result-art"
                disabled={waiting ||
                  (result.kind === 'web' && !importsEnabled) ||
                  (result.kind === 'local' && result.result.track.status === 'pending')}
                aria-label={language.t(playing ? 'tracks.pause' : 'tracks.play', {
                  title: track.title,
                })}
                aria-busy={waiting}
                onclick={() => activate(result, true)}
              >
                {#if result.kind === 'web' && result.track.artwork_url}
                  <img
                    src={result.track.artwork_url}
                    alt=""
                    loading="lazy"
                    referrerpolicy="no-referrer"
                  />
                {:else if result.kind === 'local'}
                  <TrackArtwork track={result.result.track} />
                {:else if result.kind === 'service'}
                  <TrackArtwork track={result.track} />
                {:else}<Icon name="music" />{/if}
                <span class="search-art-play">
                  {#if waiting}
                    <span class="spinner"></span>
                  {:else}<Icon name={playing ? 'pause' : 'play'} />{/if}
                </span>
              </button>
              <button
                class="search-result-action"
                disabled={waiting ||
                  (result.kind === 'web' && !importsEnabled) ||
                  (result.kind === 'local' && result.result.track.status === 'pending')}
                aria-label={language.t(playing ? 'tracks.pause' : 'tracks.play', {
                  title: track.title,
                })}
                onclick={() => activate(result)}
              >
                <span class="search-result-text">
                  <strong>{track.title}</strong>
                  <span
                    >{track.artist} · {language.t(
                      result.kind === 'local'
                        ? 'search.library'
                        : result.kind === 'service'
                          ? 'search.service'
                          : result.track.provider === 'deezer'
                            ? 'search.deezer'
                            : 'search.itunes',
                    )}</span
                  >
                </span>
              </button>
              {#if result.kind === 'web'}
                <button
                  class="icon-button search-result-more"
                  data-search-menu={searchTrackKey(result.track)}
                  aria-haspopup="menu"
                  aria-label={language.t('tracks.actions', { title: track.title })}
                  onclick={(event) => menu(result.track, event.currentTarget)}
                  ><Icon name="more" /></button
                >
                <button
                  class="icon-button search-result-add"
                  class:added={controller.web.additions[searchTrackKey(result.track)] === 'added'}
                  disabled={!importsEnabled ||
                    !!controller.web.additions[searchTrackKey(result.track)]}
                  aria-label={controller.web.additions[searchTrackKey(result.track)] === 'added'
                    ? language.t('web.added')
                    : language.t('web.addTrack', { title: track.title })}
                  title={language.t('web.addTrack', { title: track.title })}
                  onclick={() => {
                    controller.remember(result);
                    add(result.track);
                  }}
                >
                  {#if controller.web.additions[searchTrackKey(result.track)] === 'adding'}<span
                      class="spinner"
                    ></span>
                  {:else}<Icon
                      name={controller.web.additions[searchTrackKey(result.track)] === 'added'
                        ? 'library-added'
                        : 'library-add'}
                    />{/if}
                </button>
              {:else if result.kind === 'service'}
                <button
                  class="icon-button search-result-more"
                  data-search-menu={result.track.id}
                  aria-haspopup="menu"
                  aria-label={language.t('tracks.actions', { title: track.title })}
                  onclick={(event) => serviceMenu(result.track, event.currentTarget)}
                  ><Icon name="more" /></button
                >
                <button
                  class="icon-button search-result-add"
                  class:added={controller.serviceAdditions[result.track.id] === 'added'}
                  disabled={!!controller.serviceAdditions[result.track.id]}
                  aria-label={controller.serviceAdditions[result.track.id] === 'added'
                    ? language.t('web.added')
                    : language.t('web.addTrack', { title: track.title })}
                  onclick={() => addService(result.track)}
                >
                  {#if controller.serviceAdditions[result.track.id] === 'adding'}
                    <span class="spinner"></span>
                  {:else}
                    <Icon
                      name={controller.serviceAdditions[result.track.id] === 'added'
                        ? 'library-added'
                        : 'library-add'}
                    />
                  {/if}
                </button>
              {/if}
            </li>
          {/each}
        </ul>
      {:else}
        <p class="search-message" role="status">
          {language.t(
            controller.query.trim()
              ? controller.query.trim().length < 2
                ? 'search.moreCharacters'
                : 'web.empty'
              : 'search.recentEmpty',
          )}
        </p>
      {/if}
    </div>
    <CollectionScrollbar target={dropdown} label={language.t('search.results')} />
  {/if}
</div>
