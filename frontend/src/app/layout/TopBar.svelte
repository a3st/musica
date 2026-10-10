<script lang="ts">
  import { getApplication } from '../context';
  import Icon from '../../shared/ui/Icon.svelte';
  import Brand from '../../shared/ui/Brand.svelte';
  import SearchBox from '../../features/search/ui/SearchBox.svelte';
  const app = getApplication();
  let profileOpen = $state(false);
  let profile: HTMLDivElement;
  let toggle: HTMLButtonElement;
  function close(event: MouseEvent): void {
    if (event.target instanceof Node && !profile.contains(event.target)) profileOpen = false;
  }
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
      app.libraryOpen = true;
    }}><Icon name="library" /></button
  >
  <SearchBox
    state={app.search}
    language={app.language}
    play={(result) => app.run(app.playSearchResult(result))}
    playWeb={(track) => app.run(app.playWebTrack(track))}
    menu={(track, origin) => app.showWebTrackMenu(track, origin)}
    ownsContextMenu={!!app.menu.origin?.hasAttribute('data-search-menu')}
    waitingTrackKey={app.player.value.loading ? app.search.web.playingTrackKey : null}
    add={(track) => {
      app.run(app.addWebTrack(track));
    }}
  />
  <div class="topbar-actions">
    <button
      class="button upload-button desktop-only"
      data-action="upload"
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
        }}
        ><span class="user-avatar"
          ><span class="avatar-label">{app.auth.user?.username[0].toLocaleUpperCase() ?? 'M'}</span
          ></span
        ></button
      >
      <div id="profile-menu" class="profile-menu" hidden={!profileOpen}>
        <button
          id="theme-toggle"
          class="profile-menu-item"
          title={app.language.t(
            app.theme.value === 'dark' ? 'profile.lightTheme' : 'profile.darkTheme',
          )}
          onclick={() => app.theme.toggle()}
          ><Icon name={app.theme.value === 'dark' ? 'sun' : 'moon'} />{app.language.t(
            app.theme.value === 'dark' ? 'profile.lightTheme' : 'profile.darkTheme',
          )}</button
        >
        <label class="profile-menu-item"
          >{app.language.t('profile.language')}<select
            id="language"
            aria-label={app.language.t('profile.language')}
            value={app.language.locale}
            onchange={(event) => app.language.set(event.currentTarget.value)}
            ><option value="ru-RU">Русский</option><option value="en-US">English (US)</option
            ></select
          ></label
        >
        <button
          class="profile-menu-item"
          data-action="logout"
          hidden={!app.auth.user}
          onclick={() => app.run(app.logout())}>{app.language.t('profile.signOut')}</button
        >
      </div>
    </div>
  </div>
</header>
