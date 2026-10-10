<script lang="ts">
  import Dialog from '../../../shared/ui/Dialog.svelte';
  import Icon from '../../../shared/ui/Icon.svelte';
  import type { UploadsState } from '../state.svelte';
  import type { LanguageState } from '../../../shared/i18n/state.svelte';
  let {
    state: controller,
    language,
    spotify,
  }: { state: UploadsState; language: LanguageState; spotify: () => void } = $props();
  let input: HTMLInputElement;
  let dragging = $state(false);
</script>

<Dialog id="upload-dialog" class="upload-dialog" bind:open={controller.open}>
  <div class="dialog-heading">
    <div>
      <span class="eyebrow">{language.t('uploads.eyebrow')}</span>
      <h2>{language.t('uploads.heading')}</h2>
    </div>
    <button
      class="icon-button"
      data-close
      aria-label={language.t('uploads.close')}
      onclick={() => {
        controller.open = false;
      }}><Icon name="close" /></button
    >
  </div>
  <p class="muted">{language.t('uploads.description')}</p>
  <div
    class="drop-zone"
    role="button"
    aria-label={language.t('uploads.chooseFiles')}
    onclick={(event) => {
      if (event.target !== input) input.click();
    }}
    class:dragging
    id="drop-zone"
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
      if (event.dataTransfer?.files) controller.add(event.dataTransfer.files);
    }}
  >
    <Icon name="upload" /><strong>{language.t('uploads.dropFiles')}</strong><span
      >{language.t('common.or')} <u>{language.t('uploads.chooseFiles')}</u></span
    ><small>{language.t('uploads.formats')}</small>
    <input
      bind:this={input}
      id="file-input"
      type="file"
      accept="audio/*,.mp3,.flac,.wav,.ogg,.aac,.m4a,.webm"
      multiple
      hidden
      onchange={(event) => {
        if (event.currentTarget.files) controller.add(event.currentTarget.files);
        event.currentTarget.value = '';
      }}
    />
  </div>
  <button
    class="button secondary spotify-import-link"
    data-action="spotify-import"
    onclick={spotify}>{language.t('spotify.title')}</button
  >
  <div id="upload-list" class="upload-list" aria-live="polite">
    {#each controller.queue as item (item.key)}
      <div class={`upload-item ${item.state}`} data-upload-key={item.key}>
        <div class="file-symbol"><Icon name={item.state === 'done' ? 'check' : 'music'} /></div>
        <div class="upload-item-main">
          {#if item.state === 'waiting'}<div class="upload-fields">
              <input
                data-upload-title={item.key}
                aria-label={language.t('uploads.titleField', { filename: item.file.name })}
                bind:value={item.title}
                maxlength="256"
                required
              /><input
                data-upload-artist={item.key}
                aria-label={language.t('uploads.artistField', { filename: item.file.name })}
                bind:value={item.artist}
                maxlength="256"
                required
              />
            </div>{:else}<strong>{item.title}</strong><span>{item.artist}</span>{/if}
          <small
            >{item.state === 'error'
              ? (item.error ?? language.t('uploads.failed'))
              : item.state === 'uploading'
                ? language.t('uploads.progress', { progress: item.progress })
                : item.state === 'preparing'
                  ? language.t('uploads.preparing')
                  : item.state === 'done'
                    ? language.t('uploads.ready')
                    : item.state === 'cancelled'
                      ? language.t('uploads.cancelled')
                      : language.t('uploads.fileDetails', {
                          size: (item.file.size / 1024 / 1024).toFixed(1),
                          filename: item.file.name,
                        })}</small
          >
          {#if item.state === 'uploading'}<progress
              value={item.progress}
              max="100"
              aria-label={language.t('uploads.progressLabel', { title: item.title })}
            ></progress>{/if}
        </div>
        {#if item.state === 'error'}<button
            class="icon-button"
            data-retry-upload={item.key}
            aria-label={language.t('uploads.retry')}
            onclick={() => controller.retry(item)}><Icon name="refresh" /></button
          >{/if}
        {#if item.state !== 'preparing'}<button
            class="icon-button"
            data-remove-upload={item.key}
            aria-label={language.t(
              item.state === 'uploading' ? 'uploads.cancel' : 'uploads.remove',
            )}
            onclick={() => controller.remove(item)}><Icon name="close" /></button
          >{:else}<span class="spinner" aria-label={language.t('tracks.preparing')}></span>{/if}
      </div>
    {/each}
  </div>
  <div class="upload-footer">
    <span class="muted">{language.t('uploads.targetHint')}</span><button
      id="start-upload"
      class="button primary"
      disabled={!controller.canStart}
      onclick={() => {
        void controller.start();
      }}>{language.t('uploads.submit')}<Icon name="arrow" /></button
    >
  </div>
</Dialog>
