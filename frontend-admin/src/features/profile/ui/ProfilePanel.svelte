<script lang="ts">
  import { getApplication } from '../../../app/context';
  import { profileApi } from '../api';
  import Dialog from '../../../shared/ui/Dialog.svelte';
  import Select from '../../../shared/ui/Select.svelte';
  import Icon from '../../../shared/ui/Icon.svelte';

  const app = getApplication();
  let action = $state<'password' | 'delete'>('password');
  let open = $state(false);
  let password = $state('');
  let newPassword = $state('');
  let repeatPassword = $state('');
  let busy = $state(false);
  let error = $state('');

  /** Открывает подтверждение операции с чистой формой. */
  function show(value: typeof action): void {
    reset();
    action = value;
    open = true;
  }

  /** Удаляет чувствительные данные при закрытии формы. */
  function reset(): void {
    password = '';
    newPassword = '';
    repeatPassword = '';
    error = '';
  }

  /** Выполняет подтверждённую операцию; при успехе возвращает к форме входа. */
  async function submit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (busy) return;
    error = '';
    if (action === 'password' && newPassword !== repeatPassword) {
      error = app.language.t('profile.mismatch');
      return;
    }
    busy = true;

    try {
      if (action === 'password') await profileApi.changePassword(password, newPassword);
      else await profileApi.remove(password);
      app.notice = app.language.t(
        action === 'password' ? 'profile.passwordChanged' : 'profile.deleted',
      );
      open = false;
      app.signedOut();
    } catch (failure) {
      error = app.failure(failure);
    } finally {
      password = '';
      busy = false;
    }
  }
</script>

<section class="settings-page">
  <h1>{app.language.t('profile.title')}</h1>
  <section class="settings-section">
    <h2>{app.language.t('profile.account')}</h2>
    <div class="settings-row">
      <span>{app.language.t('profile.username')}</span>
      <strong>{app.user?.username}</strong>
    </div>
    <div class="settings-row">
      <span
        >{app.language.t('profile.password')}<small>{app.language.t('profile.passwordHint')}</small
        ></span
      >
      <button class="button" onclick={() => show('password')}
        ><Icon name="edit" />{app.language.t('profile.changePassword')}</button
      >
    </div>
  </section>
  <section class="settings-section">
    <h2>{app.language.t('profile.language')}</h2>
    <div class="settings-row">
      <span>{app.language.t('profile.languageHint')}</span>
      <Select
        id="language"
        label={app.language.t('profile.language')}
        value={app.language.locale}
        options={[
          { value: 'ru-RU', label: 'Русский' },
          { value: 'en-US', label: 'English (US)' },
        ]}
        onchange={(value) => app.language.set(value)}
      />
    </div>
  </section>
  <section class="settings-section red-zone">
    <h2>{app.language.t('profile.delete')}</h2>
    <div class="settings-row">
      <span>{app.language.t('profile.deleteHint')}</span>
      <button class="button danger-outline" onclick={() => show('delete')}
        ><Icon name="trash" />{app.language.t('profile.delete')}</button
      >
    </div>
  </section>
</section>

<Dialog id="profile-dialog" bind:open dismissible={!busy} onclose={reset}>
  <div class="dialog-heading">
    <h2>{app.language.t(action === 'password' ? 'profile.changePassword' : 'profile.delete')}</h2>
    <button
      class="icon-button"
      aria-label={app.language.t('common.close')}
      disabled={busy}
      onclick={() => (open = false)}><Icon name="close" /></button
    >
  </div>
  {#if action === 'delete'}<p class="muted">{app.language.t('profile.deleteConfirm')}</p>{/if}
  <form onsubmit={submit}>
    <label
      >{app.language.t('profile.currentPassword')}<input
        type="password"
        autocomplete="current-password"
        required
        minlength="12"
        maxlength="1024"
        bind:value={password}
      /></label
    >
    {#if action === 'password'}
      <label
        >{app.language.t('profile.newPassword')}<input
          type="password"
          autocomplete="new-password"
          required
          minlength="12"
          maxlength="1024"
          bind:value={newPassword}
        /></label
      >
      <label
        >{app.language.t('profile.repeatPassword')}<input
          type="password"
          autocomplete="new-password"
          required
          minlength="12"
          maxlength="1024"
          bind:value={repeatPassword}
        /></label
      >
    {/if}
    <p class="form-error" role="alert">{error}</p>
    <div class="dialog-buttons">
      <button type="button" class="button" disabled={busy} onclick={() => (open = false)}
        >{app.language.t('common.cancel')}</button
      >
      <button
        class="button"
        class:primary={action === 'password'}
        class:danger={action === 'delete'}
        disabled={busy}
        >{app.language.t(
          busy
            ? 'common.loading'
            : action === 'password'
              ? 'profile.changePassword'
              : 'profile.delete',
        )}</button
      >
    </div>
  </form>
</Dialog>
