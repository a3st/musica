<script lang="ts">
  import { onMount, untrack } from 'svelte';
  import { registerSW } from 'virtual:pwa-register';
  import { Application } from './state.svelte';
  import { setApplication } from './context';
  import AppLayout from './layout/AppLayout.svelte';
  import Icon from '../shared/ui/Icon.svelte';
  import Brand from '../shared/ui/Brand.svelte';
  import Dialog from '../shared/ui/Dialog.svelte';
  import ContextMenu from '../shared/ui/ContextMenu.svelte';
  import AuthDialog from '../features/auth/ui/AuthDialog.svelte';
  import PlaylistNav from '../features/playlists/ui/PlaylistNav.svelte';
  import PlaylistEditor from '../features/playlists/ui/PlaylistEditor.svelte';
  import UploadDialog from '../features/uploads/ui/UploadDialog.svelte';
  import SpotifyDialog from '../features/spotify-import/ui/SpotifyDialog.svelte';

  const app = new Application();

  setApplication(app);

  $effect(() => app.player.engine.setAudioSettings(app.settings.audio));

  let confirmOpen = $state(false);
  let updateSW: (reload?: boolean) => Promise<void> = async () => {};

  $effect(() => {
    document.documentElement.lang = app.language.locale;
    untrack(() => app.menu.close(false));
  });

  $effect(() => {
    document.documentElement.dataset.theme = app.theme.value;
    const meta = document.querySelector<HTMLMetaElement>('meta[name="theme-color"]');
    if (meta) meta.content = app.theme.value === 'dark' ? '#0b0f1c' : '#f1f5f9';
  });

  $effect(() => {
    document.querySelector('#app')?.classList.toggle('queue-open', app.player.queueOpen);
    document.querySelector('#app')?.classList.toggle('lyrics-open', app.player.lyricsOpen);
  });

  $effect(() => {
    const track = app.player.value.current;
    document.title = track
      ? app.player.value.paused
        ? app.language.t('app.title')
        : `${track.title} — ${track.artist} · ${app.language.t('app.title')}`
      : app.language.t('app.title');
  });

  $effect(() => {
    confirmOpen = app.confirmation !== null;
  });

  onMount(() => {
    let active = true;
    updateSW = registerSW({
      onNeedRefresh: () => {
        if (active) app.updateAvailable = true;
      },
      onRegisterError: (error) => console.error('Service worker registration failed', error),
    });
    void app.start();
    const polling = setInterval(() => {
      void app.poll();
    }, 5000);

    return () => {
      active = false;
      clearInterval(polling);
      app.dispose();
    };
  });

  /** Обрабатывает горячие клавиши плеера, не перехватывая ввод и открытое меню. */
  function keydown(event: KeyboardEvent): void {
    if (event.defaultPrevented || app.menu.opened) return;

    if (event.key === 'Escape' && app.player.lyricsOpen) {
      app.player.lyricsOpen = false;
      document.querySelector<HTMLButtonElement>('#lyrics-toggle')?.focus();

      return;
    }
    if (event.key === 'Escape' && app.player.queueOpen) app.player.queueOpen = false;
    if (
      event.code === 'Space' &&
      event.target instanceof HTMLElement &&
      !event.target.closest('input,textarea,select,button,[contenteditable],dialog')
    ) {
      event.preventDefault();
      app.player.engine.toggle();
    }
  }
</script>

<svelte:document
  onkeydown={keydown}
  onvisibilitychange={() => {
    app.language.sync();
    void app.checkSession();
  }}
/>
<svelte:window
  onfocus={() => {
    app.language.sync();
    void app.checkSession();
  }}
  onstorage={() => app.language.sync()}
  onpageshow={() => void app.checkSession()}
  onhashchange={() => app.run(app.openSession())}
  ononline={() => {
    app.online = true;
    if (app.auth.user) app.run(app.refresh());
  }}
  onoffline={() => {
    app.online = false;
  }}
/>
<AppLayout />
<Dialog id="library-dialog" class="library-sheet" bind:open={app.libraryOpen}>
  <div class="dialog-heading">
    <Brand label={app.language.t('app.home')} /><button
      class="icon-button"
      data-close
      aria-label={app.language.t('navigation.closePlaylists')}
      onclick={() => {
        app.libraryOpen = false;
      }}><Icon name="close" /></button
    >
  </div>
  <PlaylistNav
    state={app.library}
    language={app.language}
    create={() => app.createPlaylist()}
    select={(id) => app.run(app.selectPlaylist(id))}
    menu={(playlist, origin, point) => app.showPlaylistMenu(playlist, origin, point)}
  />
  <button class="button upload-button" data-action="upload" onclick={() => app.upload()}
    ><Icon name="cloud" />{app.language.t('uploads.title')}</button
  >
</Dialog>
<AuthDialog
  bind:open={app.authOpen}
  authenticated={app.auth.user !== null}
  language={app.language}
/>
<PlaylistEditor state={app.editor} language={app.language} />
<UploadDialog
  state={app.uploads}
  language={app.language}
  spotify={() => app.importSpotify()}
  spotifyEnabled={app.capabilities.spotify_import}
/>
{#if app.capabilities.spotify_import}
  <SpotifyDialog state={app.spotify} language={app.language} />
{/if}
<ContextMenu menu={app.menu} />
<Dialog
  id="confirm-dialog"
  bind:open={confirmOpen}
  onclose={() => {
    if (!app.confirmationBusy) app.confirmation = null;
  }}
>
  <div class="dialog-heading">
    <h2 id="confirm-title">{app.confirmation?.title ?? ''}</h2>
    <button
      class="icon-button"
      data-close
      aria-label={app.language.t('common.close')}
      disabled={app.confirmationBusy}
      onclick={() => {
        app.confirmation = null;
      }}><Icon name="close" /></button
    >
  </div>
  <p id="confirm-description" class="muted">{app.confirmation?.description ?? ''}</p>
  <div class="dialog-buttons">
    <button
      class="button secondary"
      data-close
      disabled={app.confirmationBusy}
      onclick={() => {
        app.confirmation = null;
      }}>{app.language.t('common.cancel')}</button
    ><button
      class="button danger"
      id="confirm-delete"
      disabled={app.confirmationBusy}
      onclick={() => {
        void app.confirm();
      }}>{app.language.t('common.delete')}</button
    >
  </div>
</Dialog>
<div id="connection" class="connection" role="status" hidden={app.online}>
  {app.language.t('app.offline')}
</div>
<div id="toast" role="status" class="toast" hidden={!app.toast || (!app.auth.user && app.authOpen)}>
  {app.toast}
</div>
<button
  id="update"
  class="update-button"
  hidden={!app.updateAvailable}
  onclick={() => {
    if (app.uploads.busy) app.notify(app.language.t('app.finishUploads'));
    else app.run(updateSW(true));
  }}>{app.language.t('app.updateAvailable')}</button
>
