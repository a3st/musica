<script lang="ts">
  import Icon from './Icon.svelte';

  let {
    id,
    name,
    label,
    value,
    options,
    disabled = false,
    onchange,
  }: {
    id: string;
    name?: string;
    label: string;
    value: string;
    options: { value: string; label: string }[];
    disabled?: boolean;
    onchange: (value: string) => void;
  } = $props();
  let open = $state(false);
  let upward = $state(false);
  let active = $state(0);
  let root: HTMLDivElement;
  let trigger: HTMLButtonElement;
  const selected = $derived(options.find((option) => option.value === value));

  $effect(() => {
    if (!open) return;
    const rect = trigger.getBoundingClientRect();
    const panel = root.closest('main, dialog')?.getBoundingClientRect();
    const below = Math.min(window.innerHeight, panel?.bottom ?? window.innerHeight) - rect.bottom;
    const above = rect.top - Math.max(0, panel?.top ?? 0);
    upward = below < options.length * 40 + 16 && above > below;
  });

  function choose(index: number): void {
    const option = options[index];
    if (!option || disabled) return;
    onchange(option.value);
    open = false;
    trigger.focus();
  }

  function keydown(event: KeyboardEvent): void {
    if (event.key === 'Escape') {
      open = false;
      event.stopPropagation();
      return;
    }
    if (event.key === 'Tab') {
      open = false;
      return;
    }
    if (!['ArrowDown', 'ArrowUp', 'Home', 'End', 'Enter', ' '].includes(event.key)) return;
    event.preventDefault();
    if (!open) {
      active = Math.max(
        0,
        options.findIndex((option) => option.value === value),
      );
      open = true;
      return;
    }
    if (event.key === 'Enter' || event.key === ' ') choose(active);
    else
      active =
        event.key === 'Home'
          ? 0
          : event.key === 'End'
            ? options.length - 1
            : (active + (event.key === 'ArrowDown' ? 1 : -1) + options.length) % options.length;
  }
</script>

<svelte:document
  onpointerdown={(event) => {
    if (event.target instanceof Node && !root.contains(event.target)) open = false;
  }}
  onfocusin={(event) => {
    if (event.target instanceof Node && !root.contains(event.target)) open = false;
  }}
/>
<div class="select" bind:this={root}>
  <select
    {id}
    {name}
    {value}
    {disabled}
    hidden
    aria-hidden="true"
    tabindex="-1"
    onchange={(event) => onchange(event.currentTarget.value)}
  >
    {#each options as option}<option value={option.value}>{option.label}</option>{/each}
  </select>
  <button
    bind:this={trigger}
    id={`${id}-toggle`}
    type="button"
    class="select-trigger"
    {disabled}
    role="combobox"
    aria-label={label}
    aria-expanded={open}
    aria-controls={`${id}-options`}
    aria-haspopup="listbox"
    aria-activedescendant={open ? `${id}-option-${active}` : undefined}
    onkeydown={keydown}
    onclick={() => {
      active = Math.max(
        0,
        options.findIndex((option) => option.value === value),
      );
      open = !open;
    }}
  >
    <span>{selected?.label ?? ''}</span><Icon name="chevron-down" />
  </button>
  {#if open}
    <div id={`${id}-options`} class="select-options" class:upward role="listbox" aria-label={label}>
      {#each options as option, index (option.value)}
        <button
          id={`${id}-option-${index}`}
          type="button"
          role="option"
          tabindex="-1"
          aria-selected={option.value === value}
          class:active={active === index}
          onpointermove={() => (active = index)}
          onclick={() => choose(index)}
          >{option.label}{#if option.value === value}<Icon name="check" />{/if}</button
        >
      {/each}
    </div>
  {/if}
</div>

<style>
  .select {
    position: relative;
    width: 100%;
    min-width: 0;
  }
  .select-trigger {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 20px;
    width: 100%;
    min-height: 38px;
    padding: 9px 16px;
    border: 1px solid transparent;
    border-radius: 5px;
    background: var(--surface);
    color: var(--muted);
    text-align: left;
    font: inherit;
    font-size: 13px;
    cursor: pointer;
  }
  .select-trigger:hover,
  .select-trigger[aria-expanded='true'] {
    border-color: var(--border);
    color: var(--text);
  }
  .select-trigger span {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .select :global(svg) {
    width: 16px;
    height: 16px;
    flex-shrink: 0;
  }
  .select-options {
    position: absolute;
    inset: calc(100% + 6px) 0 auto;
    z-index: 60;
    padding: 5px;
    border: 1px solid var(--border);
    border-radius: 7px;
    background: var(--surface);
    box-shadow: 0 12px 30px #0003;
  }
  .select-options button {
    display: flex;
    align-items: center;
    justify-content: space-between;
    width: 100%;
    gap: 12px;
    padding: 10px;
    border: 0;
    border-radius: 4px;
    background: transparent;
    color: var(--text);
    font: inherit;
    font-size: 13px;
    text-align: left;
    cursor: pointer;
  }
  .select-options button.active {
    background: var(--active);
  }
  .select-options.upward {
    top: auto;
    bottom: calc(100% + 6px);
  }
</style>
