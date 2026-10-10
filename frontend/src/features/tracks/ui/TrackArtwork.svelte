<script lang="ts">
  import Icon from '../../../shared/ui/Icon.svelte';
  import type { Track } from '../model';
  import { trackArtworkUrl } from '../image';
  import './TrackArtwork.css';

  let {
    track,
    shareToken = null,
    eager = false,
  }: {
    track: Pick<Track, 'id' | 'artwork_key'>;
    shareToken?: string | null;
    eager?: boolean;
  } = $props();

  const url = $derived(trackArtworkUrl(track, shareToken));
  let failedUrl = $state<string | null>(null);
</script>

<span
  class="track-art track-artwork"
  style={`--art-hue:${parseInt(track.id.slice(0, 4), 16) % 260}`}
  aria-hidden="true"
>
  {#if url && failedUrl !== url}
    <img
      src={url}
      alt=""
      loading={eager ? 'eager' : 'lazy'}
      onerror={(event) => {
        failedUrl = event.currentTarget.getAttribute('src');
      }}
    />
  {:else}
    <Icon name="music" />
  {/if}
</span>
