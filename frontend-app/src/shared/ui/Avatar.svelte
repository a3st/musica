<script lang="ts">
  import { avatar } from './avatar';

  let { name, size = 38 }: { name: string; size?: number } = $props();
  const appearance = $derived(avatar(name));
</script>

<span
  class="initial-avatar"
  aria-hidden="true"
  style={`--avatar-size:${size}px;--avatar-color:${appearance.color}`}>{appearance.initials}</span
>

<style>
  .initial-avatar {
    display: inline-grid;
    place-items: center;
    flex-shrink: 0;
    width: var(--avatar-size);
    height: var(--avatar-size);
    border-radius: 50%;
    background: var(--avatar-color);
    color: #fff;
    font-size: calc(var(--avatar-size) * 0.42);
    font-weight: 500;
    line-height: 1;
    user-select: none;
  }
</style>
