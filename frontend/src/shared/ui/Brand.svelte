<script lang="ts">
  import Icon from './Icon.svelte';
  let { label }: { label: string } = $props();
</script>

<a class="brand" href="/" aria-label={label}
  ><span class="brand-mark"><Icon name="play" /></span><span class="brand-name">musica</span></a
>

<style>
  .brand-name {
    line-height: 1;
    transform: translateY(-2px);
  }
</style>
