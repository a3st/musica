<script lang="ts">
  import { onMount } from 'svelte';
  import { Application } from './state.svelte';
  import { setApplication } from './context';
  import ProfilePage from '../pages/ProfilePage.svelte';
  import StoragePage from '../pages/StoragePage.svelte';
  import UsersPage from '../pages/UsersPage.svelte';
  import AuthDialog from '../features/auth/ui/AuthDialog.svelte';
  import Avatar from '../shared/ui/Avatar.svelte';
  import Icon from '../shared/ui/Icon.svelte';
  import { playerUrl } from '../shared/navigation/player';

  const app = new Application();
  const player = playerUrl();
  let profileOpen = $state(false);
  let profile = $state<HTMLDivElement>();

  /** Закрывает меню профиля при клике снаружи или Escape. */
  function closeProfile(event: MouseEvent | KeyboardEvent): void {
    if (event instanceof KeyboardEvent) {
      if (event.key === 'Escape') profileOpen = false;
    } else if (event.target instanceof Node && profile && !profile.contains(event.target)) {
      profileOpen = false;
    }
  }
  setApplication(app);

  onMount(() => {
    const controller = new AbortController();
    void app.initialize(controller.signal);
    return () => controller.abort();
  });

  $effect(() => {
    document.documentElement.lang = app.language.locale;
    document.title = app.language.t('admin.title');
  });
</script>

<svelte:window
  onpopstate={() => app.restorePage()}
  onstorage={() => app.language.sync()}
  onfocus={() => app.language.sync()}
/>
<svelte:document
  onclick={closeProfile}
  onkeydown={closeProfile}
  onvisibilitychange={() => app.language.sync()}
/>
<div class="admin-shell">
  <header class="topbar">
    <a class="brand" href={player} aria-label={app.language.t('admin.home')}>
      <img src={`${import.meta.env.BASE_URL}icon.svg`} width="32" height="32" alt="" /><span
        >musica</span
      >
    </a>
    {#if app.user}
      <div class="profile-actions" bind:this={profile}>
        <button
          id="profile-toggle"
          class="profile"
          onclick={() => (profileOpen = !profileOpen)}
          aria-label={app.language.t('profile.menu')}
          aria-expanded={profileOpen}
          aria-controls="profile-menu"
        >
          <span class="avatar-ring"><Avatar name={app.user.username} size={32} /></span>
        </button>
        {#if profileOpen}
          <div id="profile-menu" class="profile-menu">
            <button
              onclick={() => {
                profileOpen = false;
                void app.logout();
              }}
            >
              <Icon name="logout" />{app.language.t('common.logout')}
            </button>
          </div>
        {/if}
      </div>
    {/if}
  </header>
  <div class="workspace">
    <aside class="sidebar">
      <nav aria-label={app.language.t('nav.label')}>
        <button
          class:active={app.page === 'profile'}
          aria-current={app.page === 'profile' ? 'page' : undefined}
          onclick={() => app.selectPage('profile')}
          ><Icon name="profile" />{app.language.t('nav.profile')}</button
        >
        {#if app.user?.role === 'admin'}
          <button
            class:active={app.page === 'users'}
            aria-current={app.page === 'users' ? 'page' : undefined}
            onclick={() => app.selectPage('users')}
            ><Icon name="users" />{app.language.t('nav.users')}</button
          >
          <button
            class:active={app.page === 'storage'}
            aria-current={app.page === 'storage' ? 'page' : undefined}
            onclick={() => app.selectPage('storage')}
            ><Icon name="storage" />{app.language.t('nav.storage')}</button
          >
        {/if}
      </nav>
    </aside>
    <main>
      {#if app.user}
        {#if app.error}<p class="form-error" role="alert">{app.error}</p>{/if}
        {#if app.page === 'storage' && app.user.role === 'admin'}<StoragePage
          />{:else if app.page === 'users' && app.user.role === 'admin'}<UsersPage
          />{:else}<ProfilePage />{/if}
      {:else}
        <div class="placeholder" aria-hidden="true">
          <div></div>
          <div></div>
          <div></div>
        </div>
      {/if}
    </main>
  </div>
</div>
{#if app.loading}<div class="loading" role="status">
    {app.language.t('common.loading')}
  </div>{:else if !app.user}<AuthDialog />{/if}

<style>
  .admin-shell {
    width: min(1480px, 100%);
    margin-inline: auto;
    padding: 18px;
  }

  .topbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 20px;
    min-height: 74px;
    padding: 16px 24px;
    border: 1px solid var(--border);
    border-radius: 18px;
    background: var(--surface);
  }

  .brand {
    display: inline-flex;
    align-items: center;
    gap: 10px;
    color: var(--accent);
    font-size: 26px;
    font-weight: 800;
    letter-spacing: -1px;
  }

  .profile-actions,
  .profile {
    display: flex;
    align-items: center;
    gap: 14px;
  }

  .profile {
    padding: 3px;
    background: transparent;
    border: 0;
    border-radius: 24px;
    font-size: 13px;
    font-weight: 600;
  }

  .profile:active {
    transform: scale(0.97);
  }

  .profile-actions {
    position: relative;
  }

  .profile-menu {
    position: absolute;
    top: calc(100% + 10px);
    right: 0;
    z-index: 20;
    min-width: 180px;
    padding: 6px;
    border: 1px solid var(--border);
    border-radius: 12px;
    background: var(--surface);
    box-shadow: 0 12px 32px #18243b18;
  }

  .profile-menu button {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    padding: 12px;
    border: 0;
    border-radius: 8px;
    background: transparent;
    text-align: left;
  }

  .profile-menu button:hover {
    background: var(--hover);
  }

  .avatar-ring {
    display: inline-flex;
    padding: 3px;
    border: 2px solid var(--accent);
    border-radius: 50%;
  }

  .workspace {
    display: grid;
    grid-template-columns: 240px minmax(0, 1fr);
    gap: 18px;
    margin-top: 18px;
    min-height: calc(100dvh - 128px);
  }

  .sidebar,
  main {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 18px;
    min-width: 0;
  }

  .sidebar {
    padding: 14px;
    align-self: start;
  }

  nav button {
    display: flex;
    align-items: center;
    gap: 12px;
    width: 100%;
    padding: 14px;
    border: 0;
    border-radius: 9px;
    background: transparent;
    color: var(--muted);
    text-align: left;
    font-size: 13px;
    margin-bottom: 5px;
  }

  nav button:hover {
    background: var(--hover);
  }

  nav button.active {
    background: var(--active);
    color: var(--accent);
    font-weight: 600;
  }

  main {
    padding: 40px;
  }

  .placeholder {
    padding: 30px;
  }

  .placeholder div {
    height: 60px;
    margin-bottom: 40px;
    border-radius: 10px;
    background: var(--input);
  }

  .loading {
    position: fixed;
    inset: 0;
    display: grid;
    place-items: center;
    background: var(--page);
  }

  @media (max-width: 760px) {
    .admin-shell {
      padding: 10px;
    }

    .topbar {
      padding: 12px;
      gap: 8px;
    }

    .profile-actions {
      gap: 6px;
    }

    .workspace {
      grid-template-columns: minmax(0, 1fr);
      grid-template-rows: auto 1fr;
      margin-top: 10px;
      gap: 10px;
    }

    .sidebar {
      padding: 8px;
    }

    nav {
      display: flex;
      flex-wrap: nowrap;
      overflow-x: auto;
      gap: 6px;
    }

    nav button {
      width: auto;
      flex-shrink: 0;
      margin: 0;
      padding: 9px;
      gap: 8px;
      font-size: 12px;
      white-space: nowrap;
    }

    main {
      padding: 24px 20px;
    }
  }
</style>
