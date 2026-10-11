<script lang="ts">
  import Select from '../../../shared/ui/Select.svelte';
  import Dialog from '../../../shared/ui/Dialog.svelte';
  import Icon from '../../../shared/ui/Icon.svelte';
  import type { LanguageState } from '../../../shared/i18n/state.svelte';
  import type { PlaylistEditorState } from '../editor.svelte';
  let { state: controller, language }: { state: PlaylistEditorState; language: LanguageState } =
    $props();
  let input: HTMLInputElement;
  let dragging = $state(false);
  let preview = $state<string | null>(null);
  $effect(() => {
    const file = controller.image;
    const url = file ? URL.createObjectURL(file) : null;
    preview = url;
    return () => {
      if (url) URL.revokeObjectURL(url);
    };
  });
</script>

<Dialog
  id="playlist-dialog"
  bind:open={controller.open}
  onclose={() => {
    controller.image = null;
  }}
>
  <div class="dialog-heading">
    <h2 id="playlist-editor-title">
      {language.t(controller.id ? 'playlists.edit' : 'playlists.new')}
    </h2>
    <button
      class="icon-button"
      data-close
      aria-label={language.t('common.close')}
      onclick={() => {
        controller.open = false;
      }}><Icon name="close" /></button
    >
  </div>
  <form
    id="playlist-form"
    onsubmit={(event) => {
      event.preventDefault();
      void controller.save();
    }}
  >
    <div
      class="playlist-image-drop"
      role="button"
      aria-label={language.t('playlists.artwork')}
      onclick={(event) => {
        if (event.target !== input) input.click();
      }}
      class:dragging
      id="playlist-image-drop"
      tabindex="0"
      onkeydown={(event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          input.click();
        }
      }}
      ondragenter={(event) => {
        event.preventDefault();
        dragging = true;
      }}
      ondragover={(event) => {
        event.preventDefault();
        dragging = true;
      }}
      ondragleave={() => {
        dragging = false;
      }}
      ondrop={(event) => {
        event.preventDefault();
        dragging = false;
        if (event.dataTransfer?.files[0]) controller.chooseImage(event.dataTransfer.files[0]);
      }}
    >
      <img
        id="playlist-image-preview"
        src={preview ?? controller.existingImage ?? undefined}
        alt=""
        hidden={!preview && !controller.existingImage}
      />
      <span
        ><Icon name="upload" /><strong>{language.t('playlists.artwork')}</strong><small
          >{language.t('playlists.artworkHint')}</small
        ></span
      >
      <input
        bind:this={input}
        id="playlist-image-input"
        type="file"
        accept="image/png,image/jpeg,image/webp"
        hidden
        disabled={controller.busy}
        onchange={(event) => {
          const file = event.currentTarget.files?.[0];
          if (file) controller.chooseImage(file);
          event.currentTarget.value = '';
        }}
      />
    </div>
    <button
      type="button"
      class="text-button"
      id="playlist-image-clear"
      hidden={!controller.image}
      disabled={controller.busy}
      onclick={() => {
        controller.image = null;
      }}>{language.t('playlists.artworkDiscard')}</button
    >
    <label
      >{language.t('playlists.title')}<input
        name="title"
        maxlength="256"
        placeholder={language.t('playlists.titlePlaceholder')}
        required
        bind:value={controller.title}
        disabled={controller.busy}
      /></label
    >
    <label
      >{language.t('playlists.description')}
      <span class="muted">· {language.t('common.optional')}</span><textarea
        name="description"
        maxlength="4096"
        rows="3"
        placeholder={language.t('playlists.descriptionPlaceholder')}
        bind:value={controller.description}
        disabled={controller.busy}></textarea></label
    >
    <div class="visibility-field">
      <span>{language.t('playlists.visibility')}</span>
      <Select
        id="playlist-visibility"
        name="visibility"
        label={language.t('playlists.visibility')}
        value={controller.visibility}
        disabled={controller.busy}
        options={(['private', 'public', 'unlisted'] as const).map((value) => ({
          value,
          label: language.t(`playlists.${value}`),
        }))}
        onchange={(value) => (controller.visibility = value as typeof controller.visibility)}
      />
    </div>
    <p class="form-error" role="alert">{controller.error}</p>
    <button id="playlist-save" class="button primary wide" disabled={controller.busy}
      >{language.t(controller.id ? 'common.save' : 'playlists.create')}<Icon
        name={controller.id ? 'check' : 'plus'}
      /></button
    >
  </form>
</Dialog>

<style>
  .visibility-field {
    display: grid;
    gap: 10px;
    margin: 18px 0;
    font-size: 13px;
  }
</style>
