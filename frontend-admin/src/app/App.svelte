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

<div class="admin-shell">
  <header class="topbar">
    <a class="brand" href={player} aria-label={app.language.t('admin.home')}>
      <img src="/icon.svg" width="32" height="32" alt="" /><span>musica</span>
    </a>
    {#if app.user}
      <div class="profile-actions">
        <button
          class="profile"
          onclick={() => (app.page = 'profile')}
          aria-label={app.language.t('nav.profile')}
          ><span>{app.user.username}</span><span class="avatar-ring"
            ><Avatar name={app.user.username} size={32} /></span
          ></button
        >
        <button class="button logout" onclick={() => app.logout()}
          ><Icon name="logout" /><span>{app.language.t('common.logout')}</span></button
        >
      </div>
    {/if}
  </header>
  <div class="workspace">
    <aside class="sidebar">
      <span class="nav-label">{app.language.t('nav.label')}</span>
      <nav aria-label={app.language.t('nav.label')}>
        <button
          class:active={app.page === 'profile'}
          aria-current={app.page === 'profile' ? 'page' : undefined}
          onclick={() => (app.page = 'profile')}
          ><Icon name="profile" />{app.language.t('nav.profile')}</button
        >
        {#if app.user?.role === 'admin'}
          <button
            class:active={app.page === 'users'}
            aria-current={app.page === 'users' ? 'page' : undefined}
            onclick={() => (app.page = 'users')}
            ><Icon name="users" />{app.language.t('nav.users')}</button
          >
          <button
            class:active={app.page === 'storage'}
            aria-current={app.page === 'storage' ? 'page' : undefined}
            onclick={() => (app.page = 'storage')}
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

  .profile > span:first-child {
    max-width: 180px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
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
    padding: 28px 14px;
  }

  .nav-label {
    display: block;
    padding: 0 14px 20px;
    font-size: 10px;
    color: var(--muted);
    text-transform: uppercase;
    letter-spacing: 1.5px;
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

    .profile > span:first-child,
    .logout span {
      display: none;
    }

    .profile-actions {
      gap: 6px;
    }

    .workspace {
      grid-template-columns: minmax(0, 1fr);
      margin-top: 10px;
      gap: 10px;
    }

    .sidebar {
      padding: 8px;
    }

    .nav-label {
      display: none;
    }

    nav {
      display: flex;
      flex-wrap: wrap;
      gap: 6px;
    }

    nav button {
      width: auto;
      margin: 0;
      padding: 10px;
    }

    main {
      padding: 24px 20px;
    }
  }
</style>
