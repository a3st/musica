<script lang="ts">
  import Dialog from '../../../shared/ui/Dialog.svelte';
  import Icon from '../../../shared/ui/Icon.svelte';
  import { getApplication } from '../../../app/context';

  const app = getApplication();
  let open = $state(true);
  let username = $state('');
  let password = $state('');
  let registering = $state(false);
  let busy = $state(false);
  let error = $state('');

  /** Выполняет вход или регистрацию; очищает пароль из состояния после запроса. */
  async function submit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (busy) return;
    busy = true;
    error = '';

    try {
      await app.signIn(username, password, registering);
    } catch (failure) {
      error = app.failure(failure);
    } finally {
      password = '';
      busy = false;
    }
  }
</script>

<Dialog id="auth-dialog" class="auth-dialog" bind:open dismissible={false}>
  <span class="eyebrow">{app.language.t('auth.welcome')}</span>
  <h2>
    {app.language.t(registering ? 'auth.registerHeading' : 'auth.heading')}<br />{app.language.t(
      registering ? 'auth.registerSuffix' : 'auth.suffix',
    )}<span>.</span>
  </h2>
  <p class="muted">{app.language.t('auth.subtitle')}</p>
  {#if app.notice}<p class="notice" role="status">{app.notice}</p>{/if}
  <form id="auth-form" onsubmit={submit}>
    <label
      >{app.language.t('auth.username')}<input
        name="username"
        autocomplete="username"
        minlength="3"
        maxlength="64"
        pattern="[a-z0-9_]+"
        placeholder="music_lover"
        required
        bind:value={username}
      /></label
    >
    <label
      >{app.language.t('auth.password')}<input
        name="password"
        type="password"
        autocomplete={registering ? 'new-password' : 'current-password'}
        minlength="12"
        maxlength="1024"
        placeholder={app.language.t('auth.placeholder')}
        required
        bind:value={password}
      /></label
    >
    <p id="auth-error" class="form-error" role="alert">{error || app.error}</p>
    <button id="auth-submit" class="button primary wide" disabled={busy}
      >{busy
        ? app.language.t('common.loading')
        : app.language.t(registering ? 'auth.register' : 'auth.signIn')}<Icon
        name="arrow"
      /></button
    >
  </form>
  {#if app.registrationEnabled}<button
      id="auth-switch"
      class="text-button auth-switch"
      disabled={busy}
      onclick={() => {
        registering = !registering;
        password = '';
        error = '';
      }}>{app.language.t(registering ? 'auth.loginLink' : 'auth.registerLink')}</button
    >{/if}
</Dialog>

<style>
  :global(.auth-dialog) {
    padding: 36px;
    max-width: 440px;
  }

  h2 {
    font-size: 36px;
    letter-spacing: -1.6px;
    line-height: 1.15;
    margin: 20px 0;
  }

  h2 span {
    color: var(--accent);
  }

  .eyebrow {
    font-size: 9px;
    letter-spacing: 1.5px;
  }

  .muted {
    margin-bottom: 28px;
  }

  .auth-switch {
    display: block;
    margin: 20px auto 0;
    border: 0;
    background: transparent;
    color: var(--accent);
    cursor: pointer;
  }

  @media (max-width: 760px) {
    :global(.auth-dialog) {
      padding: 25px;
    }

    h2 {
      font-size: 31px;
    }
  }
</style>
