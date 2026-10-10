<script lang="ts">
  import { onDestroy, tick, untrack } from 'svelte';
  import MenuList from './MenuList.svelte';
  import type { MenuItem, MenuState } from './menu.svelte';
  let { menu }: { menu: MenuState } = $props();
  let root: HTMLDivElement;
  let child: HTMLDivElement;
  let expanded = $state.raw<MenuItem | null>(null);
  let parent = $state.raw<HTMLButtonElement | null>(null);
  onDestroy(() => {
    root?.remove();
    child?.remove();
  });
  const buttons = (element: HTMLElement) => [
    ...element.querySelectorAll<HTMLButtonElement>('button:not(:disabled)'),
  ];
  function closeChild(focus = false): void {
    expanded = null;
    if (focus) parent?.focus({ preventScroll: true });
    parent = null;
    if (root) root.style.maxHeight = '';
  }
  async function place(): Promise<void> {
    await tick();
    if (!menu.opened || !menu.origin) return;
    const host = menu.origin.closest('dialog') ?? document.querySelector('#app')!;
    if (root.parentElement !== host) host.append(root, child);
    const anchor = menu.origin.getBoundingClientRect();
    const rect = root.getBoundingClientRect();
    root.style.left = `${Math.max(8, Math.min(menu.point?.x ?? anchor.left, window.innerWidth - rect.width - 8))}px`;
    const top =
      menu.point?.y ??
      (anchor.bottom + rect.height + 4 <= window.innerHeight - 8
        ? anchor.bottom + 4
        : anchor.top - rect.height - 4);
    root.style.top = `${Math.max(8, Math.min(top, window.innerHeight - rect.height - 8))}px`;
    buttons(root)[0]?.focus({ preventScroll: true });
  }
  $effect(() => {
    menu.opened;
    menu.items;
    untrack(() => {
      closeChild();
      if (menu.opened) void place();
    });
  });
  async function showChild(
    item: MenuItem,
    button: HTMLButtonElement,
    focus = false,
  ): Promise<void> {
    if (button.disabled || !item.children?.length) return;
    expanded = item;
    parent = button;
    await tick();
    if (!expanded || !menu.opened) return;
    child.style.maxHeight = '';
    let rect = root.getBoundingClientRect();
    const size = child.getBoundingClientRect();
    let left: number;
    let top = Math.max(
      8,
      Math.min(button.getBoundingClientRect().top - 7, window.innerHeight - size.height - 8),
    );
    if (rect.right + size.width + 4 <= window.innerWidth - 8) left = rect.right + 4;
    else if (rect.left - size.width - 4 >= 8) left = rect.left - size.width - 4;
    else {
      root.style.maxHeight = `${(window.innerHeight - 28) / 2}px`;
      root.style.top = '8px';
      rect = root.getBoundingClientRect();
      left = Math.max(8, Math.min(rect.left, window.innerWidth - size.width - 8));
      top = rect.bottom + 4;
      child.style.maxHeight = `${window.innerHeight - top - 8}px`;
    }
    child.style.left = `${left}px`;
    child.style.top = `${top}px`;
    if (focus) buttons(child)[0]?.focus({ preventScroll: true });
  }
  function select(item: MenuItem, button: HTMLButtonElement): void {
    if (item.children?.length) void showChild(item, button, true);
    else {
      menu.close();
      item.action?.();
    }
  }
  function hover(item: MenuItem, button: HTMLButtonElement): void {
    if (item.children?.length) void showChild(item, button);
    else closeChild();
  }
  function outside(event: PointerEvent): void {
    if (
      !menu.opened ||
      !(event.target instanceof Node) ||
      root.contains(event.target) ||
      child.contains(event.target)
    )
      return;
    if (
      event.button === 0 &&
      menu.origin?.matches('[data-track-menu]') &&
      menu.origin.contains(event.target)
    )
      return;
    menu.close(false);
  }
  function keydown(event: KeyboardEvent): void {
    if (!menu.opened) return;
    if (event.key === 'Escape') {
      event.preventDefault();
      if (expanded) closeChild(true);
      else menu.close();
      return;
    }
    if (event.key === 'Tab') {
      menu.close(false);
      return;
    }
    if (event.key === 'ArrowRight') {
      const index = buttons(root).indexOf(document.activeElement as HTMLButtonElement);
      const button = buttons(root)[index];
      const item = menu.items.find((item) =>
        item.id ? item.id === button?.id : item.label === button?.textContent?.trim(),
      );
      if (item?.children && button) {
        event.preventDefault();
        void showChild(item, button, true);
      }
    }
    if (event.key === 'ArrowLeft' && expanded) {
      event.preventDefault();
      closeChild(true);
    }
    if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
      event.preventDefault();
      const items = buttons(child.contains(document.activeElement) ? child : root);
      const index = items.indexOf(document.activeElement as HTMLButtonElement);
      const next =
        event.key === 'Home'
          ? 0
          : event.key === 'End'
            ? items.length - 1
            : (index + (event.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
      items[next]?.focus({ preventScroll: true });
    }
  }
  function scroll(event: Event): void {
    if (
      !menu.opened ||
      !(event.target instanceof Node) ||
      root.contains(event.target) ||
      child.contains(event.target)
    )
      return;
    const rect = menu.origin?.getBoundingClientRect();
    if (
      !rect ||
      Math.abs(rect.left - menu.anchor.x) > 0.5 ||
      Math.abs(rect.top - menu.anchor.y) > 0.5
    )
      menu.close(false);
  }
</script>

<svelte:document onpointerdown={outside} onkeydown={keydown} onscrollcapture={scroll} />
<svelte:window onresize={() => menu.close(false)} />
<div bind:this={root} id="context-menu" class="context-menu" role="menu" hidden={!menu.opened}>
  <MenuList items={menu.items} {expanded} {select} {hover} />
</div>
<div
  bind:this={child}
  id="context-submenu"
  class="context-menu context-submenu"
  role="menu"
  aria-label={expanded?.label}
  hidden={!menu.opened || !expanded}
>
  <MenuList items={expanded?.children ?? []} {select} hover={() => {}} />
</div>

<style>
  .context-menu {
    position: fixed;
    z-index: 80;
    width: min(280px, calc(100vw - 16px));
    max-height: calc(100dvh - 16px);
    overflow: auto;
    padding: 7px;
    border: 1px solid var(--border);
    border-radius: 14px;
    background: var(--surface);
    box-shadow: 0 16px 50px #0006;
    scrollbar-width: thin;
    scrollbar-color: var(--range) transparent;
  }
  .context-submenu {
    z-index: 81;
  }
</style>
