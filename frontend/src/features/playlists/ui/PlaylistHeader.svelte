<script lang="ts">
  import CoverArt from './CoverArt.svelte';
  import type { Playlist } from '../model';
  import type { User } from '../../auth/model';
  import type { LanguageState } from '../../../shared/i18n/state.svelte';
  let {
    playlist,
    user,
    language,
    canReadImage,
    menu,
  }: {
    playlist: Playlist;
    user: User | null;
    language: LanguageState;
    canReadImage: boolean;
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
  <div class="hero-cover"><CoverArt {playlist} {canReadImage} /></div>
  <div class="hero-text">
    <span class="eyebrow"
      >{language.t(playlist.is_default ? 'library.label' : 'playlists.playlistLabel')}</span
    >
    <h1 id="playlist-title">{playlist.title}</h1>
    {#if playlist.description}<p>{playlist.description}</p>{/if}
    <div class="hero-facts">
      <span class="owner-avatar">{owner[0].toLocaleUpperCase()}</span><strong>{owner}</strong><span
        class="fact-dot">·</span
      ><span>{language.t('playlists.summary', { count: playlist.tracks.length })}</span>
    </div>
  </div>
</section>
