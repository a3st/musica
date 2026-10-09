import { t } from './i18n';

export function initCollectionScrollbar(): void {
  const main = document.querySelector<HTMLElement>('#collection')!;
  const rail = document.createElement('div'); rail.className = 'collection-scrollbar';
  const thumb = document.createElement('div'); thumb.className = 'collection-scrollbar-thumb';
  thumb.role = 'scrollbar'; thumb.tabIndex = 0;
  thumb.setAttribute('aria-controls', 'collection'); thumb.setAttribute('aria-orientation', 'vertical');
  thumb.setAttribute('aria-valuemin', '0'); thumb.setAttribute('aria-valuemax', '100');
  rail.append(thumb); document.querySelector('.workspace')!.append(rail);
  let travel = 0; let offset = 0; let dragging = false;
  function update(): void {
    const rect = main.getBoundingClientRect(); const height = Math.max(0, rect.height - 24);
    const maximum = main.scrollHeight - main.clientHeight;
    rail.hidden = maximum <= 1 || height < 40;
    rail.style.top = `${rect.top + 12}px`; rail.style.left = `${rect.right - 11}px`; rail.style.height = `${height}px`;
    const length = Math.min(80, Math.max(32, height * main.clientHeight / main.scrollHeight)); travel = height - length;
    thumb.style.height = `${length}px`; thumb.style.top = `${maximum > 0 ? main.scrollTop / maximum * travel : 0}px`;
    thumb.setAttribute('aria-valuenow', String(Math.round(maximum > 0 ? main.scrollTop / maximum * 100 : 0)));
    thumb.setAttribute('aria-label', t('Прокрутка плейлиста'));
  }
  function scrollAt(y: number): void {
    if (travel > 0) main.scrollTop = Math.max(0, Math.min(1, (y - rail.getBoundingClientRect().top - offset) / travel)) * (main.scrollHeight - main.clientHeight);
  }
  rail.onpointerdown = (event) => {
    if (event.button !== 0) return;
    event.preventDefault(); offset = event.target === thumb ? event.clientY - thumb.getBoundingClientRect().top : thumb.offsetHeight / 2;
    dragging = true; rail.setPointerCapture(event.pointerId); rail.classList.add('dragging'); thumb.focus(); scrollAt(event.clientY);
  };
  rail.onpointermove = (event) => { if (dragging) scrollAt(event.clientY); };
  rail.onpointerup = rail.onlostpointercapture = () => { dragging = false; rail.classList.remove('dragging'); };
  rail.addEventListener('wheel', (event) => { event.preventDefault(); main.scrollTop += event.deltaY; }, { passive: false });
  thumb.onkeydown = (event) => {
    const amount = { ArrowDown: 40, ArrowUp: -40, PageDown: main.clientHeight, PageUp: -main.clientHeight, Home: -main.scrollHeight, End: main.scrollHeight }[event.key];
    if (amount !== undefined) { event.preventDefault(); main.scrollTop += amount; }
  };
  main.addEventListener('scroll', update);
  new ResizeObserver(update).observe(main);
  new MutationObserver(update).observe(main, { childList: true, subtree: true, characterData: true });
  window.addEventListener('localechange', update); update();
}
