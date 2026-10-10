<script lang="ts">
  import Dialog from '../../../shared/ui/Dialog.svelte';
  import Icon from '../../../shared/ui/Icon.svelte';
  import { ApiError, errorMessage } from '../../../shared/api/errors';
  import type { LanguageState } from '../../../shared/i18n/state.svelte';
  let {
    open = $bindable(false),
    authenticated = false,
    language,
    signIn,
  }: {
    open?: boolean;
    authenticated?: boolean;
    language: LanguageState;
    signIn: (username: string, password: string, register: boolean) => Promise<void>;
  } = $props();
  let registering = $state(false);
  let busy = $state(false);
  let error = $state('');
  let username = $state('');
  let password = $state('');
  async function submit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (busy) return;
    busy = true;
    error = '';
    try {
      await signIn(username, password, registering);
      username = '';
      password = '';
    } catch (failure) {
      error =
        failure instanceof ApiError && failure.status === 401
          ? language.t('auth.invalidCredentials')
          : errorMessage(failure);
    } finally {
      busy = false;
    }
  }
</script>

<Dialog id="auth-dialog" class="auth-dialog" bind:open dismissible={authenticated}>
  <div class="dialog-heading">
    <span class="eyebrow">{language.t('auth.welcome')}</span>
    {#if authenticated}<button
        class="icon-button"
        data-close
        aria-label={language.t('common.close')}
        onclick={() => {
          open = false;
        }}><Icon name="close" /></button
      >{/if}
  </div>
  <h2 id="auth-title">
    {language.t(registering ? 'auth.registerHeading' : 'auth.loginHeading')}<br />{language.t(
      registering ? 'auth.registerSuffix' : 'auth.loginSuffix',
    )}<span>.</span>
  </h2>
  <p class="muted">{language.t('auth.subtitle')}</p>
  <form id="auth-form" onsubmit={submit}>
    <label
      >{language.t('auth.username')}<input
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
      >{language.t('auth.password')}<input
        name="password"
        type="password"
        autocomplete={registering ? 'new-password' : 'current-password'}
        minlength="12"
        maxlength="1024"
        placeholder={language.t('auth.passwordPlaceholder')}
        required
        bind:value={password}
      /></label
    >
    <p id="auth-error" class="form-error" role="alert">{error}</p>
    <button class="button primary wide" id="auth-submit" disabled={busy}
      >{language.t(registering ? 'auth.register' : 'auth.signIn')}<Icon name="arrow" /></button
    >
  </form>
  <button
    class="text-button auth-switch"
    id="auth-switch"
    onclick={() => {
      registering = !registering;
      error = '';
    }}>{language.t(registering ? 'auth.loginLink' : 'auth.registerLink')}</button
  >
</Dialog>
