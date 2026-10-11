<script lang="ts">
  import Icon from '../../../shared/ui/Icon.svelte';
  import { type Preset } from '../model';
  import Select from '../../../shared/ui/Select.svelte';
  import Equalizer from './Equalizer.svelte';
  import type { SettingsState } from '../state.svelte';
  import type { LanguageState } from '../../../shared/i18n/state.svelte';
  import type { ThemeState } from '../../../shared/theme/state.svelte';

  let {
    settings,
    language,
    theme,
    close,
  }: {
    settings: SettingsState;
    language: LanguageState;
    theme: ThemeState;
    close: () => void;
  } = $props();
</script>

<section class="settings-page">
  <div class="dialog-heading">
    <h1>{language.t('settings.title')}</h1>
    <button
      id="settings-close"
      class="icon-button"
      aria-label={language.t('common.close')}
      onclick={close}><Icon name="close" /></button
    >
  </div>
  <section class="settings-section">
    <h2>{language.t('settings.appearance')}</h2>
    <div class="settings-row">
      <span>{language.t('settings.theme')}</span>
      <Select
        id="theme-toggle"
        label={language.t('settings.theme')}
        value={theme.value}
        options={[
          { value: 'dark', label: language.t('settings.dark') },
          { value: 'light', label: language.t('settings.light') },
        ]}
        onchange={(value) => theme.set(value as 'dark' | 'light')}
      />
    </div>
  </section>
  <section class="settings-section">
    <h2>{language.t('profile.language')}</h2>
    <div class="settings-row">
      <span>{language.t('settings.languageHint')}</span>
      <Select
        id="language"
        label={language.t('profile.language')}
        value={language.locale}
        options={[
          { value: 'ru-RU', label: 'Русский' },
          { value: 'en-US', label: 'English (US)' },
        ]}
        onchange={(value) => language.set(value)}
      />
    </div>
  </section>
  <section class="settings-section">
    <h2>{language.t('settings.audio')}</h2>
    <label class="settings-row normalization" for="normalization">
      <span
        >{language.t('settings.normalization')}<small
          >{language.t('settings.normalizationHint')}</small
        ></span
      >
      <input
        id="normalization"
        type="checkbox"
        role="switch"
        checked={settings.audio.normalization}
        onchange={(event) => settings.normalize(event.currentTarget.checked)}
      />
    </label>
  </section>
  <section class="settings-section">
    <h2>{language.t('settings.playback')}</h2>
    <div class="settings-row">
      <span>{language.t('settings.equalizer')}</span>
      <Select
        id="equalizer-profile"
        label={language.t('settings.equalizer')}
        value={settings.audio.preset}
        options={(['flat', 'bass', 'vocal', 'rock', 'custom'] as const).map((value) => ({
          value,
          label: language.t(`settings.${value}`),
        }))}
        onchange={(value) => settings.profile(value as Preset)}
      />
    </div>
    <Equalizer {settings} label={language.t('settings.equalizer')} />
  </section>
  <p>{language.t('settings.saved')}</p>
</section>

<style>
  .settings-page {
    max-width: 1000px;
    margin: 0 auto;
    padding: 0;
  }
  h1 {
    margin: 0;
    font-size: 34px;
    letter-spacing: -1px;
  }
  .settings-section {
    margin-top: 36px;
  }
  h2 {
    margin: 0 0 16px;
    font-size: 16px;
  }
  .settings-row {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(160px, 265px);
    align-items: center;
    gap: 28px;
    margin-bottom: 20px;
    font-size: 14px;
    color: var(--muted);
  }
  .normalization {
    grid-template-columns: minmax(0, 1fr) auto;
  }
  small {
    display: block;
    margin-top: 6px;
    font-size: 12px;
    line-height: 1.6;
  }
  .normalization input {
    appearance: none;
    width: 42px;
    height: 24px;
    padding: 3px;
    margin: 0;
    border: 0;
    border-radius: 20px;
    background: var(--range);
    cursor: pointer;
  }
  .normalization input::before {
    content: '';
    display: block;
    width: 18px;
    height: 18px;
    border-radius: 50%;
    background: white;
    box-shadow: 0 1px 3px #0003;
    transition: transform 0.15s;
  }
  .normalization input:checked {
    background: var(--accent);
  }
  .normalization input:checked::before {
    transform: translateX(18px);
  }
  p {
    margin-top: 28px;
    color: var(--muted);
    font-size: 12px;
  }
  @media (max-width: 760px) {
    h1 {
      font-size: 28px;
    }
    .settings-row {
      grid-template-columns: minmax(0, 1fr);
      gap: 12px;
    }
    .normalization {
      grid-template-columns: minmax(0, 1fr) auto;
    }
  }
</style>
