<script lang="ts">
  import Icon from '../../../shared/ui/Icon.svelte';
  import type { Track } from '../model';
  import type { LanguageState } from '../../../shared/i18n/state.svelte';
  let {
    tracks,
    currentId,
    paused,
    loading,
    language,
    play,
    menu,
    search,
    writable,
    upload,
  }: {
    tracks: Track[];
    currentId: string | null;
    paused: boolean;
    loading: boolean;
    language: LanguageState;
    play: (track: Track) => void;
    menu: (track: Track, origin: HTMLElement, point?: { x: number; y: number }) => void;
    search: string;
    writable: boolean;
    upload: () => void;
  } = $props();
</script>

<div class="track-table">
  <div class="track-table-heading">
    <span>#</span><span>{language.t('tracks.titleColumn')}</span><span
      >{language.t('tracks.artistColumn')}</span
    ><span class="track-length">{language.t('tracks.durationColumn')}</span><span
      >{language.t('tracks.statusColumn')}</span
    ><span>{language.t('tracks.actionsColumn')}</span>
  </div>
  {#each tracks as track, index (track.id)}
    <div
      class="track-row"
      role="group"
      aria-label={track.title}
      class:is-playing={currentId === track.id}
      aria-current={currentId === track.id ? 'true' : undefined}
      data-track-row={track.id}
      oncontextmenu={(event) => {
        event.preventDefault();
        menu(track, event.currentTarget, { x: event.clientX, y: event.clientY });
      }}
    >
      <button
        class="track-play"
        data-play={track.id}
        aria-label={currentId === track.id && !paused
          ? language.t('tracks.pause', { title: track.title })
          : language.t('tracks.play', { title: track.title })}
        aria-busy={currentId === track.id && loading}
        disabled={track.status === 'pending' || (currentId === track.id && loading)}
        onclick={() => play(track)}
        ><span class="track-index">{String(index + 1).padStart(2, '0')}</span><span
          class="row-play-icon"
          ><Icon name={currentId === track.id && !paused ? 'pause' : 'play'} /></span
        ></button
      >
      <div class="track-title">
        <span
          class="track-art"
          style={`--art-hue:${(parseInt(track.id.slice(0, 4), 16) % 260) + index * 35}`}
          aria-hidden="true"><Icon name="music" /></span
        >
        <div class="track-metadata"><strong>{track.title}</strong><span>{track.artist}</span></div>
      </div>
      <span class="track-artist">{track.artist}</span><span
        class="track-length"
        aria-label={language.t('tracks.durationUnknown')}>—:—</span
      >
      <span class="track-status" class:ready-status={track.status === 'streamed'}
        >{language.t(
          track.status === 'streamed'
            ? 'tracks.ready'
            : track.status === 'ready'
              ? 'tracks.preparing'
              : 'tracks.noFile',
        )}</span
      >
      <div class="track-actions">
        <button
          class="icon-button track-more"
          data-track-menu={track.id}
          aria-haspopup="menu"
          aria-label={language.t('tracks.actions', { title: track.title })}
          onclick={(event) => menu(track, event.currentTarget)}><Icon name="more" /></button
        >
      </div>
    </div>
  {:else}
    <div class="empty-state">
      <div class="empty-icon"><Icon name={search ? 'search' : 'music'} /></div>
      <h2>{language.t(search ? 'search.noResults' : 'library.start')}</h2>
      <p>
        {language.t(search ? 'search.tryAnother' : 'library.addMusic')}
      </p>
      {#if !search && writable}<button
          class="button primary desktop-only"
          data-action="upload"
          onclick={upload}>{language.t('uploads.title')}</button
        >{/if}
    </div>
  {/each}
</div>
