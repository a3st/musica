<script lang="ts">
  import Avatar from '../../shared/ui/Avatar.svelte';
  import { getApplication } from '../context';
  import Icon from '../../shared/ui/Icon.svelte';
  import Brand from '../../shared/ui/Brand.svelte';
  import SearchBox from '../../features/search/ui/SearchBox.svelte';

  const app = getApplication();
  let profileOpen = $state(false);
  let profile: HTMLDivElement;
  let toggle: HTMLButtonElement;

  /** Закрывает меню профиля при клике снаружи. */
  function close(event: MouseEvent): void {
    if (event.target instanceof Node && !profile.contains(event.target)) profileOpen = false;
  }

  /** Закрывает меню профиля по Escape и возвращает фокус кнопке. */
  function keydown(event: KeyboardEvent): void {
    if (event.key === 'Escape' && profileOpen) {
      profileOpen = false;
      toggle.focus();
    }
  }
</script>

<svelte:document onclick={close} onkeydown={keydown} />
<header class="topbar">
  <Brand label={app.language.t('app.home')} />
  <button
    class="icon-button mobile-only"
    id="open-library"
    aria-label={app.language.t('navigation.openPlaylists')}
    onclick={() => {
      app.search.close();
      app.libraryOpen = true;
    }}><Icon name="hamburger" /></button
  >
  <SearchBox
    state={app.search}
    currentId={app.player.value.current?.id ?? null}
    paused={app.player.value.paused}
    activeWebKey={app.search.web.playingTrackId === app.player.value.current?.id
      ? app.search.web.playingTrackKey
      : null}
    language={app.language}
    importsEnabled={app.importsEnabled}
    play={(result, keepOpen) => app.run(app.playSearchResult(result, keepOpen))}
    playWeb={(track) => app.run(app.playWebTrack(track))}
    menu={(track, origin) => app.showWebTrackMenu(track, origin)}
    playService={(track) => app.run(app.playServiceTrack(track))}
    addService={(track) => app.run(app.addServiceTrack(track))}
    serviceMenu={(track, origin) => app.showServiceTrackMenu(track, origin)}
    ownsContextMenu={!!app.menu.origin?.hasAttribute('data-search-menu')}
    waitingTrackKey={app.player.value.loading ? app.search.web.playingTrackKey : null}
    waitingServiceId={app.player.value.loading ? app.player.value.current?.id : null}
    add={(track) => {
      app.run(app.addWebTrack(track));
    }}
  />
  <div class="topbar-actions">
    <button
      class="button upload-button"
      data-action="upload"
      aria-label={app.language.t('uploads.title')}
      onclick={() => app.upload()}
      ><Icon name="cloud" /><span>{app.language.t('uploads.title')}</span><span
        id="upload-count"
        hidden={!app.uploads.count}>{app.uploads.count}</span
      ></button
    >
    <div class="profile" bind:this={profile}>
      <button
        bind:this={toggle}
        id="profile-toggle"
        class="profile-toggle"
        aria-label={app.language.t('profile.menu')}
        aria-expanded={profileOpen}
        aria-controls="profile-menu"
        onclick={() => {
          profileOpen = !profileOpen;
        }}><Avatar name={app.auth.user?.username ?? 'Musica'} /></button
      >
      <div id="profile-menu" class="profile-menu" hidden={!profileOpen}>
        <a
          class="profile-menu-item"
          href="#account"
          onclick={(event) => {
            event.preventDefault();
            profileOpen = false;
            app.notify(app.language.t('profile.accountUnavailable'));
          }}><Icon name="account" />{app.language.t('profile.account')}<Icon name="external" /></a
        >
        <button
          id="open-settings"
          class="profile-menu-item"
          onclick={() => {
            profileOpen = false;
            app.openSettings();
          }}
        >
          <Icon name="settings" />{app.language.t('settings.title')}
        </button>
        <button
          class="profile-menu-item"
          data-action="logout"
          hidden={!app.auth.user}
          onclick={() => {
            profileOpen = false;
            app.run(app.logout());
          }}><Icon name="logout" />{app.language.t('profile.signOut')}</button
        >
      </div>
    </div>
  </div>
</header>
