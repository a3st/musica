<script lang="ts">
  import Brand from '../../shared/ui/Brand.svelte';
  import Icon from '../../shared/ui/Icon.svelte';
</script>

<!-- Decorative shell behind the authentication dialog; it contains no library data. -->
<div class="auth-placeholder" aria-hidden="true" inert>
  <header class="topbar">
    <Brand label="Musica" />
    <div class="placeholder-search skeleton"></div>
    <div class="placeholder-avatar skeleton"></div>
  </header>
  <aside class="sidebar">
    <div class="placeholder-heading skeleton"></div>
    {#each Array(6) as _}
      <div class="placeholder-playlist">
        <div class="placeholder-cover skeleton"></div>
        <div class="placeholder-label skeleton"></div>
      </div>
    {/each}
  </aside>
  <main id="collection" class="placeholder-collection">
    <div class="placeholder-hero">
      <div class="placeholder-art skeleton"></div>
      <div class="placeholder-details">
        <div class="placeholder-caption skeleton"></div>
        <div class="placeholder-title skeleton"></div>
        <div class="placeholder-caption skeleton"></div>
      </div>
    </div>
    <div class="placeholder-toolbar skeleton"></div>
    {#each Array(5) as _}
      <div class="placeholder-track">
        <div class="placeholder-cover skeleton"></div>
        <div class="placeholder-label skeleton"></div>
        <div class="placeholder-caption skeleton"></div>
      </div>
    {/each}
  </main>
  <footer class="player placeholder-player">
    <div class="placeholder-playlist">
      <div class="placeholder-cover skeleton"></div>
      <div class="placeholder-label skeleton"></div>
    </div>
    <div class="placeholder-transport">
      <button id="player-play" class="icon-button" disabled tabindex="-1"
        ><Icon name="play" /></button
      >
      <div class="placeholder-timeline skeleton"></div>
    </div>
  </footer>
</div>

<style>
  .auth-placeholder {
    position: fixed;
    inset: 0;
    overflow: hidden;
    pointer-events: none;
  }

  .skeleton {
    background: var(--range);
    border-radius: 8px;
    opacity: 0.55;
  }

  .placeholder-search {
    width: min(42vw, 580px);
    height: 40px;
    border-radius: 24px;
  }

  .placeholder-avatar {
    width: 38px;
    height: 38px;
    border-radius: 50%;
    margin-left: auto;
    flex-shrink: 0;
  }

  .sidebar {
    padding: 26px 20px;
  }

  .placeholder-heading {
    width: 60%;
    height: 14px;
    margin-bottom: 28px;
  }

  .placeholder-playlist {
    display: flex;
    align-items: center;
    gap: 14px;
    margin-bottom: 20px;
    min-width: 0;
  }

  .placeholder-cover {
    width: 40px;
    height: 40px;
    flex-shrink: 0;
  }

  .placeholder-label {
    height: 14px;
    width: 140px;
    max-width: 100%;
  }

  .placeholder-collection {
    right: var(--panel-gap);
    bottom: calc(var(--player-height) + 2 * var(--panel-gap));
    overflow: hidden;
  }

  .placeholder-hero {
    display: flex;
    align-items: center;
    gap: 32px;
  }

  .placeholder-art {
    width: clamp(160px, 18vw, 240px);
    aspect-ratio: 1;
    flex-shrink: 0;
    border-radius: 14px;
  }

  .placeholder-details {
    flex: 1;
    min-width: 0;
  }

  .placeholder-caption {
    width: 100px;
    height: 12px;
    max-width: 100%;
  }

  .placeholder-title {
    width: min(100%, 420px);
    height: 54px;
    margin: 24px 0;
  }

  .placeholder-toolbar {
    width: 56px;
    height: 56px;
    margin: 36px 0;
    border-radius: 50%;
  }

  .placeholder-track {
    display: flex;
    align-items: center;
    gap: 20px;
    height: 66px;
    border-top: 1px solid var(--line);
  }

  .placeholder-track .placeholder-label {
    width: min(40%, 280px);
  }

  .placeholder-track .placeholder-caption {
    margin-left: auto;
  }

  .placeholder-player .placeholder-playlist {
    margin: 0;
  }

  .placeholder-transport {
    display: grid;
    justify-items: center;
    gap: 14px;
  }

  .placeholder-timeline {
    width: 100%;
    height: 4px;
  }

  @media (max-width: 760px) {
    .placeholder-search {
      flex: 1;
      min-width: 0;
    }

    .placeholder-art {
      width: 110px;
    }

    .placeholder-hero {
      gap: 20px;
    }

    .placeholder-title {
      height: 30px;
    }

    .placeholder-player {
      grid-template-columns: minmax(0, 1fr) 110px;
    }
  }
</style>
