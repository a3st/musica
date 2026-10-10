<script lang="ts">
  import Icon from '../../../shared/ui/Icon.svelte';
  import type { Playlist } from '../model';
  let {
    playlist,
    mini = false,
    canReadImage = true,
  }: {
    playlist: Pick<Playlist, 'id' | 'is_default' | 'image_key'>;
    mini?: boolean;
    canReadImage?: boolean;
  } = $props();
  let failed = $state(false);
  $effect(() => {
    playlist.id;
    playlist.image_key;
    canReadImage;
    failed = false;
  });
</script>

{#if playlist.image_key && canReadImage && !failed}
  <img
    src={`/api/playlists/${playlist.id}/image`}
    alt=""
    loading={mini ? 'lazy' : 'eager'}
    onerror={() => {
      failed = true;
    }}
  />
{:else}
  <div
    class="cover-art"
    class:uploads-art={playlist.is_default}
    class:mix-art={!playlist.is_default}
    style={`--hue:${parseInt(playlist.id.slice(0, 4), 16) % 80}`}
  >
    <Icon name={playlist.is_default ? 'upload' : 'music'} /><span
      >{playlist.is_default ? 'UPLOADS' : 'MUSICA'}</span
    >
  </div>
{/if}
