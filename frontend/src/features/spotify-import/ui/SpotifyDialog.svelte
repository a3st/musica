<script lang="ts">
  import Dialog from '../../../shared/ui/Dialog.svelte';
  import Icon from '../../../shared/ui/Icon.svelte';
  import type { SpotifyImportStatus } from '../model';
  import type { SpotifyState } from '../state.svelte';
  import type { LanguageState } from '../../../shared/i18n/state.svelte';
  let { state: controller, language }: { state: SpotifyState; language: LanguageState } = $props();
  const summary = $derived(
    controller.readingFiles
      ? language.t('spotify.reading')
      : controller.preview && controller.input
        ? language.t('spotify.preview', {
            tracks: controller.preview.tracks,
            playlists: controller.input.playlists.length,
            skipped: controller.preview.skipped
              ? language.t('spotify.skipped', { count: controller.preview.skipped })
              : '',
          })
        : '',
  );
  const progress = $derived.by(() => {
    const current = controller.current;
    if (!current) return controller.notice;
    const count = (predicate: (track: SpotifyImportStatus['tracks'][number]) => boolean) =>
      current.tracks.filter(predicate).length;
    return (
      controller.notice ||
      language.t('spotify.status', {
        completed: count((track) => track.status === 'streamed'),
        total: current.tracks.length,
        downloading: count((track) => track.download === 'processing'),
        queued: count((track) => track.download === 'queued'),
        preparing: count((track) => track.status === 'ready' && track.preparation !== 'failed'),
        failures: controller.failed
          ? language.t('spotify.failures', { count: controller.failed })
          : '',
      })
    );
  });
</script>

<Dialog id="spotify-dialog" bind:open={controller.open}>
  <div class="dialog-heading">
    <h2>{language.t('spotify.title')}</h2>
    <button
      class="icon-button"
      data-close
      aria-label={language.t('common.close')}
      onclick={() => {
        controller.open = false;
      }}><Icon name="close" /></button
    >
  </div>
  <p class="muted">
    {language.t('spotify.description')}
  </p>
  <form
    id="spotify-form"
    onsubmit={(event) => {
      event.preventDefault();
      void controller.start();
    }}
  >
    <label
      >{language.t('spotify.files')}<input
        id="spotify-files"
        type="file"
        accept="application/json,.json"
        multiple
        required
        disabled={controller.busy}
        onchange={(event) => {
          void controller.read(Array.from(event.currentTarget.files ?? []));
        }}
      /></label
    >
    <p id="spotify-summary" aria-live="polite">{summary}</p>
    <p class="muted">
      {language.t('spotify.searchHint')}
    </p>
    <p id="spotify-error" class="form-error" role="alert">{controller.error}</p>
    <button
      id="spotify-start"
      class="button primary wide"
      disabled={!controller.input || controller.busy}
      >{language.t('spotify.submit')}<Icon name="arrow" /></button
    >
  </form>
  <p id="spotify-progress" aria-live="polite">{progress}</p>
  <button
    id="spotify-retry"
    class="button secondary"
    hidden={!controller.failed}
    disabled={controller.busy}
    onclick={() => {
      void controller.retry();
    }}>{language.t('spotify.retry')}</button
  >
</Dialog>
