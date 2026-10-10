<script lang="ts">
  import { getApplication } from '../app/context';
  import PlaylistHeader from '../features/playlists/ui/PlaylistHeader.svelte';
  import TrackTable from '../features/tracks/ui/TrackTable.svelte';
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
</script>

<PlaylistHeader
  {playlist}
  user={app.auth.user}
  language={app.language}
  {canReadImage}
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
    >{app.library.search ? app.language.t('search.foundCount', { count: tracks.length }) : ''}</span
  ><span class="collection-note"><Icon name="lock" />{visibility}</span>
</div>
<TrackTable
  {tracks}
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
