<script lang="ts">
  import type { Snippet } from 'svelte';
  let {
    id,
    open = $bindable(false),
    dismissible = true,
    class: className = '',
    children,
    onclose,
  }: {
    id: string;
    open?: boolean;
    dismissible?: boolean;
    class?: string;
    children: Snippet;
    onclose?: () => void;
  } = $props();
  let element: HTMLDialogElement;
  $effect(() => {
    if (open && !element.open) element.showModal();
    else if (!open && element.open) element.close();
  });
  function closed(): void {
    if (!dismissible && open) {
      element.showModal();
      return;
    }
    open = false;
    onclose?.();
  }
  function backdrop(event: MouseEvent): void {
    if (!dismissible || event.target !== element) return;
    const rect = element.getBoundingClientRect();
    if (
      event.clientX < rect.left ||
      event.clientX > rect.right ||
      event.clientY < rect.top ||
      event.clientY > rect.bottom
    )
      open = false;
  }
</script>

<dialog
  bind:this={element}
  {id}
  class={className}
  onclose={closed}
  oncancel={(event) => {
    if (!dismissible) event.preventDefault();
  }}
  onclick={backdrop}
>
  {@render children()}
</dialog>
