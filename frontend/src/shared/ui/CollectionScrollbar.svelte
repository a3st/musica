<script lang="ts">
  import { tick } from 'svelte';
  let {
    target,
    label,
    contained = false,
  }: {
    target: HTMLElement | undefined;
    label: string;
    contained?: boolean;
  } = $props();
  let rail: HTMLDivElement;
  let thumb: HTMLDivElement;
  let dragging = $state(false);
  let travel = 0;
  let offset = 0;
  function update(): void {
    if (!target || !rail || !thumb) return;
    const rect = target.getBoundingClientRect();
    const styles = getComputedStyle(target);
    // The rail has the same slide animation; its base position excludes the target's translation.
    const transform = new DOMMatrixReadOnly(
      styles.transform === 'none' ? undefined : styles.transform,
    );
    const top = Math.max(8, parseFloat(styles.borderTopRightRadius) || 0);
    const bottom = Math.max(8, parseFloat(styles.borderBottomRightRadius) || 0);
    const height = Math.max(0, rect.height - top - bottom);
    const maximum = target.scrollHeight - target.clientHeight;
    rail.hidden = maximum <= 1 || height < 40;
    rail.style.top = `${rect.top - transform.m42 + top}px`;
    rail.style.left = `${rect.right - transform.m41 - rail.offsetWidth}px`;
    rail.style.height = `${height}px`;
    if (contained && rail.parentElement) {
      const parent = rail.parentElement;
      const parentRect = parent.getBoundingClientRect();
      rail.style.top = `${rect.top - parentRect.top - parent.clientTop + top}px`;
      rail.style.left = `${parent.clientWidth - rail.offsetWidth}px`;
    }
    const length = Math.min(60, Math.max(24, (height * target.clientHeight) / target.scrollHeight));
    travel = height - length;
    thumb.style.height = `${length}px`;
    thumb.style.top = `${maximum > 0 ? (target.scrollTop / maximum) * travel : 0}px`;
    thumb.setAttribute(
      'aria-valuenow',
      String(Math.round(maximum > 0 ? (target.scrollTop / maximum) * 100 : 0)),
    );
  }
  $effect(() => {
    const element = target;
    if (!element) return;
    const resize = new ResizeObserver(update);
    const mutation = new MutationObserver(update);
    resize.observe(element);
    if (contained && rail.parentElement) resize.observe(rail.parentElement);
    mutation.observe(element, { childList: true, subtree: true, characterData: true });
    element.addEventListener('scroll', update);
    void tick().then(update);
    return () => {
      resize.disconnect();
      mutation.disconnect();
      element.removeEventListener('scroll', update);
    };
  });
  function scrollAt(y: number): void {
    if (target && travel > 0)
      target.scrollTop =
        Math.max(0, Math.min(1, (y - rail.getBoundingClientRect().top - offset) / travel)) *
        (target.scrollHeight - target.clientHeight);
  }
  function keydown(event: KeyboardEvent): void {
    if (!target) return;
    const amount = {
      ArrowDown: 40,
      ArrowUp: -40,
      PageDown: target.clientHeight,
      PageUp: -target.clientHeight,
      Home: -target.scrollHeight,
      End: target.scrollHeight,
    }[event.key];
    if (amount !== undefined) {
      event.preventDefault();
      target.scrollTop += amount;
    }
  }
</script>

<svelte:window onresize={update} />
<div
  bind:this={rail}
  class="collection-scrollbar"
  class:contained
  role="presentation"
  class:dragging
  hidden
  onpointerdown={(event) => {
    if (event.button !== 0) return;
    event.preventDefault();
    offset =
      event.target === thumb
        ? event.clientY - thumb.getBoundingClientRect().top
        : thumb.offsetHeight / 2;
    dragging = true;
    rail.setPointerCapture(event.pointerId);
    thumb.focus({ preventScroll: true });
    scrollAt(event.clientY);
  }}
  onpointermove={(event) => {
    if (dragging) scrollAt(event.clientY);
  }}
  onpointerup={() => {
    dragging = false;
  }}
  onlostpointercapture={() => {
    dragging = false;
  }}
  onwheel={(event) => {
    event.preventDefault();
    if (target) target.scrollTop += event.deltaY;
  }}
>
  <div
    bind:this={thumb}
    class="collection-scrollbar-thumb"
    role="scrollbar"
    tabindex="0"
    aria-controls={target?.id}
    aria-orientation="vertical"
    aria-valuemin="0"
    aria-valuemax="100"
    aria-valuenow="0"
    aria-label={label}
    onkeydown={keydown}
  ></div>
</div>
