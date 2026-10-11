<script lang="ts">
  import Dialog from '../../../shared/ui/Dialog.svelte';
  import Icon from '../../../shared/ui/Icon.svelte';
  import { profileUrl } from '../../../shared/navigation/profile';
  import type { LanguageState } from '../../../shared/i18n/state.svelte';

  let {
    open = $bindable(false),
    authenticated = false,
    language,
  }: {
    open?: boolean;
    authenticated?: boolean;
    language: LanguageState;
  } = $props();
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
    {language.t('auth.loginHeading')}<br />{language.t('auth.loginSuffix')}<span>.</span>
  </h2>
  <p class="muted">{language.t('auth.subtitle')}</p>
  <a
    class="button primary wide"
    id="auth-submit"
    href={profileUrl(true)}
    onclick={(event) => {
      event.currentTarget.href = profileUrl(true);
    }}>{language.t('auth.signIn')}<Icon name="arrow" /></a
  >
</Dialog>
