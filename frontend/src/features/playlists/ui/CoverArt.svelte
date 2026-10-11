<script lang="ts">
  import Icon from '../../../shared/ui/Icon.svelte';
  import TrackArtwork from '../../tracks/ui/TrackArtwork.svelte';
  import type { Track } from '../../tracks/model';
  import type { Playlist } from '../model';
  import { playlistImageUrl } from '../image';
  let {
    playlist,
    mini = false,
    canReadImage = true,
    shareToken = null,
  }: {
    playlist: Pick<Playlist, 'id' | 'is_default' | 'image_key'> & {
      tracks?: Pick<Track, 'id' | 'artwork_key'>[];
      cover_tracks?: Pick<Track, 'id' | 'artwork_key'>[];
    };
    mini?: boolean;
    canReadImage?: boolean;
    shareToken?: string | null;
  } = $props();
  let failed = $state(false);
  const tracks = $derived((playlist.tracks ?? playlist.cover_tracks ?? []).slice(0, 4));
  $effect(() => {
    playlist.id;
    playlist.image_key;
    canReadImage;
    failed = false;
  });
</script>

{#if playlist.image_key && canReadImage && !failed}
  <img
    src={playlistImageUrl(playlist)}
    alt=""
    loading={mini ? 'lazy' : 'eager'}
    onerror={() => {
      failed = true;
    }}
  />
{:else if playlist.is_default}
  <div class="cover-art uploads-art"><Icon name="heart" /></div>
{:else if tracks.length}
  <div class="cover-mosaic" class:single={tracks.length === 1} aria-hidden="true">
    {#each Array.from({ length: tracks.length === 1 ? 1 : 4 }, (_, index) => tracks[index]) as track, index (index)}
      {#if track}<TrackArtwork {track} {shareToken} eager={!mini} />{:else}<span class="cover-tile"
          ><Icon name="music" /></span
        >{/if}
    {/each}
  </div>
{:else}
  <div class="cover-art empty-art"><Icon name="music" /></div>
{/if}
