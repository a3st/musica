<script lang="ts">
  import { paths } from './icons';
  let { name, class: className = '' }: { name: string; class?: string } = $props();
</script>

<svg
  class={className}
  aria-hidden="true"
  viewBox="0 0 24 24"
  fill="none"
  stroke="currentColor"
  stroke-width="1.6"
  stroke-linecap="round"
  stroke-linejoin="round"
>
  {@html paths[name] ?? paths.music}
</svg>
