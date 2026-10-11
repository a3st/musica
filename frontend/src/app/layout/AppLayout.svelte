<script lang="ts">
  import { getApplication } from '../context';
  import Sidebar from './Sidebar.svelte';
  import TopBar from './TopBar.svelte';
  import CollectionScrollbar from '../../shared/ui/CollectionScrollbar.svelte';
  import AuthPlaceholder from './AuthPlaceholder.svelte';
  import Icon from '../../shared/ui/Icon.svelte';
  import SettingsPage from '../../pages/SettingsPage.svelte';
  import PlaylistPage from '../../pages/PlaylistPage.svelte';
  import PlayerBar from '../../features/player/ui/PlayerBar.svelte';
  import QueuePanel from '../../features/player/ui/QueuePanel.svelte';
  import LyricsPanel from '../../features/player/ui/LyricsPanel.svelte';
  const app = getApplication();
  const signedOut = $derived(!app.auth.user && (app.authOpen || !app.library.selected));
  let main = $state<HTMLElement | undefined>();
  let previous: string | null = null;
  $effect(() => {
    const id = app.library.selected?.id ?? null;
    if (id !== previous && main) main.scrollTop = 0;
    previous = id;
  });
</script>

{#if signedOut}
  <AuthPlaceholder />
{:else}
  <TopBar />
  <div class="library-panels" inert={app.player.lyricsOpen}>
    <Sidebar />
    <div class="workspace">
      <main
        bind:this={main}
        id="collection"
        class:playlist-view={!app.settingsOpen && !!app.library.selected}
        aria-live="polite"
        aria-busy={app.sessionLoading && !app.library.selected}
      >
        {#if app.settingsOpen}
          <SettingsPage />
        {:else if app.library.selected}
          <PlaylistPage />
        {:else if app.sessionError}
          <div class="collection-state" role="alert">
            <Icon name="music" />
            <h1>{app.language.t('playlists.loadFailed')}</h1>
            <p>{app.sessionError}</p>
            <button class="button primary" id="retry-playlist" onclick={() => app.run(app.start())}>
              {app.language.t('common.retry')}
            </button>
          </div>
        {:else}
          <div class="collection-state" role="status">
            <span class="spinner"></span>
            <p>{app.language.t('playlists.loading')}</p>
          </div>
        {/if}
      </main>
      <CollectionScrollbar target={main} label={app.language.t('playlists.scroll')} />
    </div>
  </div>
  <QueuePanel state={app.player} language={app.language} />
  <LyricsPanel state={app.player} language={app.language} />
  <PlayerBar
    state={app.player}
    language={app.language}
    inUploads={!!app.player.value.current &&
      !!app.uploadsTrackIds?.has(app.player.value.current.id)}
    adding={app.currentTrackAdding === app.player.value.current?.id}
    canAdd={!!app.auth.user && app.uploadsTrackIds !== null}
    addToUploads={() => app.run(app.toggleCurrentUploads())}
  />
{/if}

<style>
  main.playlist-view {
    padding: 0;
  }
  .library-panels {
    display: contents;
  }

  .collection-state {
    min-height: 100%;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 16px;
    text-align: center;
    color: var(--muted);
  }
  .collection-state :global(svg) {
    width: 40px;
    height: 40px;
    color: var(--accent);
  }
  .collection-state h1 {
    margin: 0;
    font-size: 24px;
    color: var(--text);
  }
  .collection-state p {
    margin: 0;
  }
</style>
