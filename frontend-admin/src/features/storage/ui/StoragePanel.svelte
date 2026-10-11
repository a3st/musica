<script lang="ts">
  import { onMount } from 'svelte';
  import { getApplication } from '../../../app/context';
  import { StorageState } from '../state.svelte';
  import { formatBytes } from '../model';
  import Dialog from '../../../shared/ui/Dialog.svelte';
  import Icon from '../../../shared/ui/Icon.svelte';

  const app = getApplication();
  const storage = new StorageState();
  let confirm = $state(false);
  const value = $derived(storage.value);
  const userShare = $derived(
    value?.source_bytes ? (value.user_bytes / value.source_bytes) * 100 : 0,
  );
  const systemShare = $derived(
    value?.source_bytes
      ? ((value.user_bytes + value.system_bytes - value.orphaned_bytes) / value.source_bytes) * 100
      : 0,
  );

  onMount(() => {
    void storage.refresh((error) => app.failure(error));
    return () => storage.dispose();
  });

  /** Запускает только явно подтверждённую очистку, закрывая подтверждение до запроса. */
  function cleanup(): void {
    confirm = false;
    void storage.cleanup((error) => app.failure(error));
  }
</script>

<section class="settings-page">
  <div class="page-heading">
    <h1>{app.language.t('storage.title')}</h1>
  </div>
  <p class="form-error" role="alert">{storage.error}</p>
  {#if storage.loading && !value}<p class="muted" role="status">
      {app.language.t('common.loading')}
    </p>{/if}
  {#if value}
    <section class="settings-section">
      <h2>{app.language.t('storage.sources')}</h2>
      <p class="muted">{app.language.t('storage.scope')}</p>
      <div class="storage-chart">
        <div
          class="donut"
          class:empty={value.source_bytes === 0}
          style={`--user-share:${userShare}%;--system-share:${systemShare}%`}
          aria-hidden="true"
        ></div>
        <div class="chart-details">
          <strong class="total-size">{formatBytes(value.source_bytes, app.language.locale)}</strong>
          <div class="legend">
            <i class="user-color"></i>{app.language.t('storage.users')}<strong
              >{formatBytes(value.user_bytes, app.language.locale)}</strong
            >
          </div>
          <div class="legend">
            <i class="system-color"></i>{app.language.t('storage.system')}<strong
              >{formatBytes(value.system_bytes - value.orphaned_bytes, app.language.locale)}</strong
            >
          </div>
          <div class="legend">
            <i class="orphan-color"></i>{app.language.t('storage.orphaned')}<strong>
              {formatBytes(value.orphaned_bytes, app.language.locale)}
            </strong>
          </div>
          {#if !value.source_bytes}<p class="muted">{app.language.t('storage.empty')}</p>{/if}
        </div>
      </div>
      <div class="counters">
        {#each [['storage.total', value.tracks], ['storage.orphaned', value.orphaned_tracks], ['storage.pending', value.pending_tracks], ['storage.segments', value.hls_segments], ['storage.jobs', value.cleanup_jobs]] as [key, count]}
          <div class="counter">
            <strong>{count}</strong><span>{app.language.t(key as 'storage.total')}</span>
          </div>
        {/each}
      </div>
    </section>
    <section class="settings-section red-zone">
      <div class="settings-row cleanup-row">
        <span
          >{app.language.t('storage.cleanup')}<small>{app.language.t('storage.orphanedHint')}</small
          ></span
        >
        <button
          class="button danger-outline"
          disabled={storage.busy || storage.loading || !value.orphaned_tracks}
          onclick={() => (confirm = true)}
        >
          <Icon name="trash" />{app.language.t(storage.busy ? 'common.loading' : 'storage.cleanup')}
        </button>
      </div>
      {#if storage.result}<p class="notice" role="status">
          {app.language.t('storage.cleanupResult', storage.result)}
        </p>{/if}
    </section>
  {/if}
</section>

<Dialog id="cleanup-dialog" bind:open={confirm}>
  <div class="dialog-heading"><h2>{app.language.t('storage.cleanup')}</h2></div>
  <p class="muted">{app.language.t('storage.cleanupConfirm')}</p>
  <div class="dialog-buttons">
    <button class="button" onclick={() => (confirm = false)}
      >{app.language.t('common.cancel')}</button
    >
    <button class="button danger" onclick={cleanup}>{app.language.t('storage.cleanup')}</button>
  </div>
</Dialog>

<style>
  .page-heading {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 16px;
  }

  .storage-chart {
    display: flex;
    align-items: center;
    gap: 36px;
    padding-block: 24px;
  }

  .donut {
    width: 180px;
    height: 180px;
    flex-shrink: 0;
    border-radius: 50%;
    background: conic-gradient(
      var(--accent) 0 var(--user-share),
      #a88be7 var(--user-share) var(--system-share),
      var(--danger) var(--system-share) 100%
    );
    position: relative;
  }

  .donut::after {
    content: '';
    position: absolute;
    inset: 25px;
    border-radius: 50%;
    background: var(--surface);
  }

  .donut.empty {
    background: var(--border);
  }

  .chart-details {
    flex: 1;
    min-width: 0;
  }

  .total-size {
    display: block;
    font-size: 32px;
    margin-bottom: 24px;
  }

  .legend {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 10px;
    margin-top: 14px;
    color: var(--muted);
    font-size: 14px;
  }

  .legend strong {
    margin-left: auto;
    color: var(--text);
  }

  .legend i {
    width: 10px;
    height: 10px;
    border-radius: 3px;
  }

  .user-color {
    background: var(--accent);
  }

  .system-color {
    background: #a88be7;
  }

  .counters {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
    gap: 12px;
  }

  .counter {
    padding: 18px;
    background: var(--input);
    border-radius: 12px;
  }

  .counter strong {
    display: block;
    font-size: 24px;
    margin-bottom: 8px;
  }

  .counter span {
    color: var(--muted);
    font-size: 12px;
  }

  .orphan-color {
    background: var(--danger);
  }

  .cleanup-row {
    align-items: center;
  }

  @media (max-width: 760px) {
    .storage-chart {
      flex-direction: column;
      align-items: stretch;
    }

    .donut {
      align-self: center;
    }

    .counters {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }
  }
</style>
