<script lang="ts">
  import { onDestroy } from 'svelte';
  import { getApplication } from '../context';
  import PlaylistNav from '../../features/playlists/ui/PlaylistNav.svelte';
  import { readPreference, writePreference } from '../../shared/utils/storage';

  const app = getApplication();
  const stored = Number(readPreference('musica:sidebar'));
  let width = $state(stored >= 80 && stored <= 340 ? Math.max(104, stored) : 256);
  let dragging = $state(false);
  let scrolling = $state(false);
  let scrollTimer: ReturnType<typeof setTimeout>;

  $effect(() => {
    document.documentElement.style.setProperty('--sidebar-width', `${width}px`);
    document.body.classList.toggle('resizing-sidebar', dragging);
  });

  onDestroy(() => {
    clearTimeout(scrollTimer);
    document.body.classList.remove('resizing-sidebar');
  });

  /** Ограничивает ширину панели и закрывает поисковую выдачу перед её сдвигом. */
  function apply(value: number): void {
    app.search.close();
    width = Math.max(104, Math.min(340, value));
  }

  /** Завершает изменение ширины и сохраняет её локально. */
  function finish(): void {
    dragging = false;
    writePreference('musica:sidebar', String(width));
  }

  /** Изменяет ширину панели с клавиатуры и сохраняет результат. */
  function keydown(event: KeyboardEvent): void {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;

    event.preventDefault();
    apply(
      event.key === 'Home'
        ? 104
        : event.key === 'End'
          ? 340
          : width + (event.key === 'ArrowLeft' ? -16 : 16),
    );
    finish();
  }

  /** Закрывает поиск и временно показывает полосу прокрутки боковой панели. */
  function scroll(): void {
    app.search.close();
    clearTimeout(scrollTimer);
    scrolling = true;
    scrollTimer = setTimeout(() => {
      scrolling = false;
    }, 800);
  }
</script>

<aside class="sidebar" class:collapsed={width < 160}>
  <PlaylistNav
    state={app.library}
    language={app.language}
    create={() => app.createPlaylist()}
    select={(id) => app.run(app.selectPlaylist(id))}
    menu={(playlist, origin, point) => app.showPlaylistMenu(playlist, origin, point)}
    {scrolling}
    onscroll={scroll}
  />
  <!-- svelte-ignore a11y_no_noninteractive_tabindex, a11y_no_noninteractive_element_interactions (Keyboard-accessible separator implements the ARIA window splitter pattern.) -->
  <div
    id="sidebar-resize"
    class="sidebar-resize"
    role="separator"
    aria-label={app.language.t('navigation.sidebarWidth')}
    aria-orientation="vertical"
    aria-valuemin="104"
    aria-valuemax="340"
    aria-valuenow={Math.round(width)}
    tabindex="0"
    onkeydown={keydown}
    onpointerdown={(event) => {
      if (event.button !== 0) return;
      event.preventDefault();
      app.search.close();
      dragging = true;
      event.currentTarget.setPointerCapture(event.pointerId);
    }}
    onpointermove={(event) => {
      if (dragging) apply(event.clientX);
    }}
    onpointerup={finish}
    onlostpointercapture={finish}
  ></div>
</aside>
