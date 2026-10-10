<script lang="ts">
  import Icon from '../../../shared/ui/Icon.svelte';
  import TrackArtwork from '../../tracks/ui/TrackArtwork.svelte';
  import { time } from '../../../shared/utils/time';
  import type { SearchState, LocalResult, RecentResult } from '../state.svelte';
  import type { SearchTrack } from '../../web-search/model';
  import type { LanguageState } from '../../../shared/i18n/state.svelte';
  import './SearchBox.css';

  let {
    state,
    language,
    play,
    add,
  }: {
    state: SearchState;
    language: LanguageState;
    play: (result: LocalResult) => void;
    add: (track: SearchTrack) => void;
  } = $props();
  let container: HTMLDivElement;
  let input: HTMLInputElement;
  let restoringFocus = false;
  const results = $derived<RecentResult[]>(
    !state.query.trim()
      ? state.recent
      : state.local.length
        ? state.local.map((result) => ({ kind: 'local' as const, result }))
        : state.web.tracks.map((track) => ({ kind: 'web' as const, track })),
  );
  const error = $derived(state.error || state.web.error);

  function closeOutside(event: MouseEvent): void {
    if (event.target instanceof Node && !container.contains(event.target)) state.close();
  }

  function keydown(event: KeyboardEvent): void {
    if (!(event.target instanceof Node) || !container.contains(event.target)) return;
    if (event.key === 'Escape' && state.open) {
      event.preventDefault();
      event.stopPropagation();
      state.close();
      restoringFocus = true;
      input.focus();
      restoringFocus = false;
    }
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
    event.preventDefault();
    state.open = true;
    const buttons = [
      ...container.querySelectorAll<HTMLButtonElement>('.search-result-action:not(:disabled)'),
    ];
    const current = buttons.indexOf(document.activeElement as HTMLButtonElement);
    const next = current + (event.key === 'ArrowDown' ? 1 : -1);
    if (next < 0 || next >= buttons.length) input.focus();
    else buttons[next].focus();
  }

  function activate(result: RecentResult): void {
    if (result.kind === 'local') play(result.result);
    else {
      state.remember(result);
      add(result.track);
    }
  }
</script>

<svelte:document
  onclick={closeOutside}
  onkeydown={keydown}
  onfocusin={(event) => {
    if (event.target instanceof Node && !container.contains(event.target)) state.close();
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
      void state.search();
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
        aria-expanded={state.open}
        aria-controls="search-results"
        aria-autocomplete="list"
        autocomplete="off"
        maxlength="256"
        value={state.query}
        oninput={(event) => state.setQuery(event.currentTarget.value)}
        onfocus={() => {
          if (restoringFocus) return;
          state.open = true;
          if (state.query.trim() && !state.searched && !state.loading) void state.search();
        }}
      />
    </label>
  </form>
  {#if state.open}
    <div
      id="search-results"
      class="search-dropdown"
      role="dialog"
      tabindex="-1"
      aria-label={language.t('search.results')}
      aria-busy={state.loading}
    >
      <h2>
        {language.t(
          !state.query.trim()
            ? 'search.recent'
            : state.local.length
              ? 'search.libraryResults'
              : 'search.results',
        )}
      </h2>
      {#if state.loading}
        <p class="search-message" role="status">
          <span class="spinner"></span>{language.t('web.searching')}
        </p>
      {:else if error}
        <div class="search-message" role="alert">
          <span>{error}</span>
          <button class="button secondary" onclick={() => void state.search()}
            >{language.t('common.retry')}</button
          >
        </div>
      {:else if results.length}
        <ul class="search-results-list">
          {#each results as result (result.kind === 'local' ? result.result.track.id : result.track.external_id)}
            {@const track = result.kind === 'local' ? result.result.track : result.track}
            <li class="search-result" data-source={result.kind}>
              <div class="search-result-art" aria-hidden="true">
                {#if result.kind === 'web' && result.track.artwork_url}
                  <img
                    src={result.track.artwork_url}
                    alt=""
                    loading="lazy"
                    referrerpolicy="no-referrer"
                  />
                {:else if result.kind === 'local'}
                  <TrackArtwork track={result.result.track} />
                {:else}<Icon name="music" />{/if}
              </div>
              <button
                class="search-result-action"
                disabled={result.kind === 'local'
                  ? result.result.track.status === 'pending'
                  : !!state.web.additions[result.track.external_id]}
                aria-label={language.t(result.kind === 'local' ? 'tracks.play' : 'web.addTrack', {
                  title: track.title,
                })}
                onclick={() => activate(result)}
              >
                <span class="search-result-text">
                  <strong>{track.title}</strong>
                  <span
                    >{track.artist} · {language.t(
                      result.kind === 'local' ? 'search.library' : 'search.itunes',
                    )}</span
                  >
                </span>
                {#if result.kind === 'local'}
                  <Icon name="play" />
                {:else}
                  <span class="search-result-duration"
                    >{result.track.duration_seconds === null
                      ? ''
                      : time(result.track.duration_seconds)}</span
                  >
                  <span class="search-result-add"
                    >{language.t(
                      state.web.additions[result.track.external_id] === 'added'
                        ? 'web.added'
                        : state.web.additions[result.track.external_id] === 'adding'
                          ? 'web.adding'
                          : 'web.add',
                    )}</span
                  >
                  <Icon name="plus" />
                {/if}
              </button>
            </li>
          {/each}
        </ul>
      {:else}
        <p class="search-message" role="status">
          {language.t(
            state.query.trim()
              ? state.query.trim().length < 2
                ? 'search.moreCharacters'
                : 'web.empty'
              : 'search.recentEmpty',
          )}
        </p>
      {/if}
    </div>
  {/if}
</div>
