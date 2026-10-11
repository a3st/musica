<script lang="ts">
  import Avatar from '../../../shared/ui/Avatar.svelte';
  import CoverArt from './CoverArt.svelte';
  import { playlistDuration } from '../duration';
  import type { Playlist } from '../model';
  import type { User } from '../../auth/model';
  import type { LanguageState } from '../../../shared/i18n/state.svelte';
  let {
    playlist,
    user,
    language,
    canReadImage,
    shareToken = null,
    menu,
  }: {
    playlist: Playlist;
    user: User | null;
    language: LanguageState;
    canReadImage: boolean;
    shareToken?: string | null;
    menu: (origin: HTMLElement, point: { x: number; y: number }) => void;
  } = $props();
  const owner = $derived(
    playlist.owner_id === user?.id ? user.username : language.t('playlists.shared'),
  );
</script>

<section
  class="playlist-hero"
  aria-labelledby="playlist-title"
  data-playlist-context={playlist.id}
  oncontextmenu={(event) => {
    event.preventDefault();
    menu(event.currentTarget, { x: event.clientX, y: event.clientY });
  }}
>
  <div class="hero-cover"><CoverArt {playlist} {canReadImage} {shareToken} /></div>
  <div class="hero-text">
    <span class="eyebrow"
      >{language.t(playlist.is_default ? 'library.label' : 'playlists.playlistLabel')}</span
    >
    <h1 id="playlist-title">{playlist.title}</h1>
    {#if playlist.description}<p>{playlist.description}</p>{/if}
    <div class="hero-facts">
      <Avatar name={owner} size={24} /><strong>{owner}</strong><span class="fact-dot">·</span><span
        >{language.t('playlists.summary', {
          count: playlist.tracks.length,
          duration: playlistDuration(playlist, language),
        })}</span
      >
    </div>
  </div>
</section>
