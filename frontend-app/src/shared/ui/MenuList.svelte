<script lang="ts">
  import Icon from './Icon.svelte';
  import type { MenuItem } from './menu.svelte';

  let {
    items,
    expanded,
    select,
    hover,
  }: {
    items: MenuItem[];
    expanded?: MenuItem | null;
    select: (item: MenuItem, button: HTMLButtonElement) => void;
    hover: (item: MenuItem, button: HTMLButtonElement) => void;
  } = $props();
</script>

{#each items as item, index}
  {#if index && item.group !== items[index - 1].group}<div
      class="context-menu-separator"
      role="separator"
    ></div>{/if}
  <button
    type="button"
    role="menuitem"
    id={item.id}
    class="context-menu-item"
    class:danger-item={item.danger}
    disabled={item.disabled ?? (!item.action && !item.children?.length)}
    title={item.hint}
    aria-haspopup={item.children?.length ? 'menu' : undefined}
    aria-expanded={item.children?.length ? expanded === item : undefined}
    aria-controls={item.children?.length ? 'context-submenu' : undefined}
    onpointerenter={(event) => hover(item, event.currentTarget)}
    onclick={(event) => select(item, event.currentTarget)}
  >
    <Icon name={item.icon ?? 'music'} /><span>{item.label}</span>
    {#if item.children?.length}<Icon name="chevron-right" />{/if}
  </button>
{/each}

<style>
  .context-menu-item {
    display: flex;
    align-items: center;
    gap: 11px;
    width: 100%;
    min-height: 40px;
    padding: 11px 12px;
    border: 0;
    border-radius: 8px;
    background: none;
    color: var(--text);
    font-size: 12px;
    text-align: left;
  }

  .context-menu-item:hover:not(:disabled),
  .context-menu-item:focus-visible,
  .context-menu-item[aria-expanded='true'] {
    background: var(--accent-soft);
    color: var(--accent);
  }

  .context-menu-item > span {
    flex: 1;
    min-width: 0;
  }

  .context-menu-item :global(svg) {
    width: 18px;
    height: 18px;
    opacity: 0.8;
  }

  .context-menu-item :global(svg:last-child:not(:first-child)) {
    width: 14px;
    height: 14px;
  }

  .context-menu-item:disabled {
    opacity: 0.4;
    cursor: default;
  }

  .danger-item {
    color: #ee7b88;
  }

  .context-menu-separator {
    height: 1px;
    margin: 5px 7px;
    background: var(--line);
  }
</style>
