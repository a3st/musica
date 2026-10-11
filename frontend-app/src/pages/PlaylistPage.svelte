<script lang="ts">
  import { getApplication } from '../app/context';
  import PlaylistHeader from '../features/playlists/ui/PlaylistHeader.svelte';
  import TrackTable from '../features/tracks/ui/TrackTable.svelte';
  import { readArtworkColor, type Color } from '../features/playlists/color';
  import { playlistImageUrl } from '../features/playlists/image';
  import { trackArtworkUrl } from '../features/tracks/image';
  import Icon from '../shared/ui/Icon.svelte';

  const app = getApplication();
  const playlist = $derived(app.library.selected!);
  const tracks = $derived(app.library.visibleTracks);
  const canPlay = $derived(tracks.some((track) => track.status !== 'pending'));
  const currentInPlaylist = $derived(
    tracks.some((track) => track.id === app.player.value.current?.id),
  );
  const playing = $derived(currentInPlaylist && !app.player.value.paused);
  const canReadImage = $derived(
    !app.library.shareToken || app.library.items.some((item) => item.id === playlist.id),
  );
  const visibility = $derived(
    playlist.is_default
      ? app.language.t('library.personal')
      : {
          private: app.language.t('playlists.privateLabel'),
          public: app.language.t('playlists.publicLabel'),
          unlisted: app.language.t('playlists.unlisted'),
        }[playlist.visibility],
  );
  let color = $state<Color>([82, 98, 116]);

  $effect(() => {
    const fallback: Color = playlist.is_default ? [100, 64, 188] : [82, 98, 116];
    color = fallback;
    const urls =
      playlist.image_key && canReadImage
        ? [playlistImageUrl(playlist)]
        : playlist.is_default
          ? []
          : playlist.tracks
              .slice(0, 4)
              .map((track) => trackArtworkUrl(track, app.library.shareToken))
              .filter((url): url is string => !!url);
    const controller = new AbortController();
    void Promise.all(urls.map((url) => readArtworkColor(url, controller.signal))).then((colors) => {
      if (controller.signal.aborted) return;

      const found = colors.filter((value): value is Color => value !== null);
      if (found.length)
        color = [0, 1, 2].map((index) =>
          Math.round(found.reduce((sum, value) => sum + value[index], 0) / found.length),
        ) as unknown as Color;
    });

    return () => controller.abort();
  });
</script>

<div class="playlist-page" style={`--cover-rgb:${color.join(' ')}`}>
  <PlaylistHeader
    {playlist}
    user={app.auth.user}
    language={app.language}
    {canReadImage}
    shareToken={app.library.shareToken}
    menu={(origin, point) => {
      const summary = app.library.items.find((item) => item.id === playlist.id) ?? {
        ...playlist,
        role: 'viewer' as const,
        track_count: playlist.tracks.length,
      };
      app.showPlaylistMenu(summary, origin, point);
    }}
  />
  <div class="collection-toolbar">
    <button
      class="button primary playlist-play"
      id="playlist-play"
      aria-label={app.language.t(playing ? 'player.pause' : 'player.playPlaylist')}
      aria-busy={currentInPlaylist && app.player.value.loading}
      disabled={!canPlay || (currentInPlaylist && app.player.value.loading)}
      onclick={() => {
        if (currentInPlaylist) {
          app.play(app.player.value.current!);
          return;
        }
        const first = tracks.find((track) => track.status !== 'pending');
        if (first) app.play(first);
      }}><Icon name={playing ? 'pause' : 'play'} /></button
    >
    <button
      class="icon-button round-button"
      id="playlist-shuffle"
      aria-label={app.language.t('player.shufflePlay')}
      disabled={!canPlay}
      onclick={() => app.shufflePlaylist()}><Icon name="shuffle" /></button
    >
    <span class="collection-label"
      >{app.library.search
        ? app.language.t('search.foundCount', { count: tracks.length })
        : ''}</span
    ><span class="collection-note"><Icon name="lock" />{visibility}</span>
  </div>
  <TrackTable
    {tracks}
    shareToken={app.library.shareToken}
    currentId={app.player.value.current?.id ?? null}
    paused={app.player.value.paused}
    loading={app.player.value.loading}
    language={app.language}
    play={(track) => app.play(track)}
    menu={(track, origin, point) => app.showTrackMenu(track, origin, point)}
    search={app.library.search}
    writable={app.library.writable(playlist.id)}
    upload={() => app.upload()}
  />
</div>

<style>
  .playlist-page {
    min-height: 100%;
    margin: 0;
    padding-bottom: 60px;
    background: linear-gradient(
      to bottom,
      rgb(var(--cover-rgb) / 0.3),
      rgb(var(--cover-rgb) / 0.1) 360px,
      transparent 680px
    );
  }

  .playlist-page :global(.playlist-hero) {
    padding: 32px;
    background: linear-gradient(
      to bottom,
      rgb(var(--cover-rgb) / 0.65),
      rgb(var(--cover-rgb) / 0.26)
    );
  }

  .playlist-page :global(.hero-cover.hero-cover) {
    width: 210px;
    height: 210px;
    border-radius: 5px;
    padding: 0;
    background: var(--surface);
  }

  .playlist-page :global(.hero-text h1) {
    font-size: clamp(36px, 5.5vw, 84px);
  }

  .playlist-page :global(.collection-toolbar) {
    padding: 24px 32px;
  }

  .playlist-page :global(.track-table.track-table) {
    margin: 0 24px;
    border: 0;
    border-radius: 0;
    background: transparent;
    box-shadow: none;
  }

  .playlist-page :global(.track-table-heading) {
    font-size: 12px;
    letter-spacing: 0;
    color: var(--muted);
  }

  .playlist-page :global(.track-row.is-playing) {
    border-radius: 6px;
    border-color: transparent;
  }

  :global(:root[data-theme='light']) .playlist-page {
    background: linear-gradient(
      to bottom,
      rgb(var(--cover-rgb) / 0.15),
      rgb(var(--cover-rgb) / 0.04) 360px,
      transparent 680px
    );
  }

  :global(:root[data-theme='light']) .playlist-page :global(.playlist-hero) {
    background: linear-gradient(
      to bottom,
      rgb(var(--cover-rgb) / 0.27),
      rgb(var(--cover-rgb) / 0.12)
    );
  }

  @media (max-width: 1200px) {
    .playlist-page {
      margin-inline: 0;
    }

    .playlist-page :global(.hero-cover.hero-cover) {
      width: 170px;
      height: 170px;
    }
  }

  @media (max-width: 760px) {
    .playlist-page {
      margin: 0;
      padding-bottom: 36px;
    }

    .playlist-page :global(.playlist-hero) {
      padding: 20px 12px;
    }

    .playlist-page :global(.hero-cover.hero-cover) {
      width: 108px;
      height: 108px;
    }

    .playlist-page :global(.hero-text h1) {
      font-size: 30px;
    }

    .playlist-page :global(.collection-toolbar) {
      padding: 20px 12px;
    }

    .playlist-page :global(.track-table.track-table) {
      margin-inline: 6px;
    }
  }

  @media (max-width: 360px) {
    .playlist-page :global(.hero-cover.hero-cover) {
      width: 90px;
      height: 90px;
    }

    .playlist-page :global(.hero-text h1) {
      font-size: 26px;
    }
  }
</style>
