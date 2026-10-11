<script lang="ts">
  import { onMount } from 'svelte';
  import { getApplication } from '../../../app/context';
  import { UsersState } from '../state.svelte';
  import { usersApi } from '../api';
  import type { RegisteredUser } from '../model';
  import Avatar from '../../../shared/ui/Avatar.svelte';
  import Icon from '../../../shared/ui/Icon.svelte';
  import Dialog from '../../../shared/ui/Dialog.svelte';

  const app = getApplication();
  const users = new UsersState();
  let creating = $state(false);
  let deleting = $state(false);
  let target = $state<RegisteredUser | null>(null);
  let username = $state('');
  let password = $state('');
  let notice = $state('');

  onMount(() => {
    void users.refresh((error) => app.failure(error));
    return () => users.dispose();
  });

  /** Создаёт пользователя и очищает пароль даже при ошибке запроса. */
  async function create(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    const success = await users.mutate(
      () => usersApi.create(username, password),
      (error) => app.failure(error),
    );
    password = '';
    if (success) {
      creating = false;
      notice = app.language.t('users.created');
    }
  }

  /** Удаляет только выбранного в подтверждении пользователя. */
  async function remove(): Promise<void> {
    if (!target) return;
    const id = target.id;
    if (
      await users.mutate(
        () => usersApi.remove(id),
        (error) => app.failure(error),
      )
    ) {
      deleting = false;
      target = null;
      notice = app.language.t('users.deleted');
    }
  }
</script>

<section class="settings-page">
  <div class="page-heading">
    <h1>{app.language.t('users.title')}</h1>
    <button
      class="button primary"
      onclick={() => {
        username = '';
        password = '';
        users.error = '';
        creating = true;
      }}><Icon name="plus" />{app.language.t('users.create')}</button
    >
  </div>
  <p class="notice" role="status">{notice}</p>
  {#if !creating && !deleting}<p class="form-error" role="alert">{users.error}</p>{/if}
  {#if users.loading}<p class="muted" role="status">{app.language.t('common.loading')}</p>{/if}
  <div class="table-scroll">
    <table>
      <thead
        ><tr
          ><th>{app.language.t('auth.username')}</th><th>{app.language.t('users.role')}</th><th
            >{app.language.t('users.date')}</th
          ><th>{app.language.t('users.tracks')}</th><th
            ><span class="sr-only">{app.language.t('users.delete')}</span></th
          ></tr
        ></thead
      >
      <tbody>
        {#each users.items as user (user.id)}
          <tr
            ><td
              ><div class="user-name">
                <Avatar name={user.username} size={32} /><span
                  >{user.username}{#if user.id === app.user?.id}<small
                      >{app.language.t('users.self')}</small
                    >{/if}</span
                >
              </div></td
            ><td>{user.role}</td><td
              >{new Date(user.created_at).toLocaleDateString(app.language.locale)}</td
            ><td>{user.tracks}</td><td
              ><button
                class="icon-button"
                aria-label={`${app.language.t('users.delete')}: ${user.username}`}
                disabled={user.id === app.user?.id || users.busy}
                onclick={() => {
                  target = user;
                  users.error = '';
                  deleting = true;
                }}><Icon name="trash" /></button
              ></td
            ></tr
          >
        {/each}
      </tbody>
    </table>
  </div>
  {#if !users.loading && !users.items.length}<p class="muted">
      {app.language.t('users.empty')}
    </p>{/if}
</section>

<Dialog
  id="create-user-dialog"
  bind:open={creating}
  dismissible={!users.busy}
  onclose={() => {
    username = '';
    password = '';
  }}
>
  <div class="dialog-heading">
    <h2>{app.language.t('users.create')}</h2>
    <button
      class="icon-button"
      disabled={users.busy}
      aria-label={app.language.t('common.close')}
      onclick={() => (creating = false)}><Icon name="close" /></button
    >
  </div>
  <p class="muted">{app.language.t('users.rules')}</p>
  <form onsubmit={create}>
    <label
      >{app.language.t('auth.username')}<input
        autocomplete="off"
        minlength="3"
        maxlength="64"
        pattern="[a-z0-9_]+"
        required
        bind:value={username}
      /></label
    >
    <label
      >{app.language.t('auth.password')}<input
        type="password"
        autocomplete="new-password"
        minlength="12"
        maxlength="1024"
        required
        bind:value={password}
      /></label
    >
    <p class="form-error" role="alert">{users.error}</p>
    <button class="button primary wide" disabled={users.busy}
      >{app.language.t(users.busy ? 'common.loading' : 'users.create')}</button
    >
  </form>
</Dialog>
<Dialog id="delete-user-dialog" bind:open={deleting} dismissible={!users.busy}>
  <div class="dialog-heading"><h2>{app.language.t('users.delete')}</h2></div>
  <p class="muted">{app.language.t('users.confirm', { username: target?.username ?? '' })}</p>
  <p class="form-error" role="alert">{users.error}</p>
  <div class="dialog-buttons">
    <button class="button" disabled={users.busy} onclick={() => (deleting = false)}
      >{app.language.t('common.cancel')}</button
    ><button class="button danger" disabled={users.busy} onclick={remove}
      >{app.language.t(users.busy ? 'common.loading' : 'users.delete')}</button
    >
  </div>
</Dialog>

<style>
  .page-heading {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 20px;
    flex-wrap: wrap;
  }

  .table-scroll {
    overflow-x: auto;
    margin-top: 28px;
  }

  table {
    width: 100%;
    border-collapse: collapse;
    text-align: left;
    font-size: 13px;
  }

  th,
  td {
    padding: 16px 12px;
    border-bottom: 1px solid var(--border);
    white-space: nowrap;
  }

  th {
    color: var(--muted);
    font-size: 11px;
    font-weight: 500;
  }

  tbody tr:hover {
    background: var(--hover);
  }

  .user-name {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  small {
    display: block;
    color: var(--muted);
    margin-top: 4px;
  }

  .sr-only {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip-path: inset(50%);
  }
</style>
