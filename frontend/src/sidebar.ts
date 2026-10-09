export function initSidebar(): void {
  const sidebar = document.querySelector<HTMLElement>('.sidebar')!;
  const handle = document.querySelector<HTMLElement>('#sidebar-resize')!;
  let width = 256;
  let dragging = false;
  function apply(value: number): void {
    width = Math.max(104, Math.min(340, value));
    document.documentElement.style.setProperty('--sidebar-width', `${width}px`);
    sidebar.classList.toggle('collapsed', width < 160);
    handle.setAttribute('aria-valuenow', String(Math.round(width)));
  }
  function save(): void { try { localStorage.setItem('musica:sidebar', String(width)); } catch { /* Optional storage. */ } }
  try { const stored = Number(localStorage.getItem('musica:sidebar')); if (stored >= 80 && stored <= 340) width = stored; } catch { /* Optional storage. */ }
  apply(width);
  let scrollTimer: ReturnType<typeof setTimeout>;
  const nav = sidebar.querySelector<HTMLElement>('.playlist-nav')!;
  nav.addEventListener('scroll', () => {
    clearTimeout(scrollTimer); nav.classList.add('scrolling');
    scrollTimer = setTimeout(() => nav.classList.remove('scrolling'), 800);
  });
  handle.onpointerdown = (event) => {
    if (event.button !== 0) return;
    event.preventDefault(); dragging = true; handle.setPointerCapture(event.pointerId);
    document.body.classList.add('resizing-sidebar');
  };
  handle.onpointermove = (event) => { if (dragging) apply(event.clientX); };
  function finish(): void { dragging = false; document.body.classList.remove('resizing-sidebar'); save(); }
  handle.onpointerup = finish; handle.onlostpointercapture = finish;
  handle.onkeydown = (event) => {
    if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight' && event.key !== 'Home' && event.key !== 'End') return;
    event.preventDefault(); apply(event.key === 'Home' ? 104 : event.key === 'End' ? 340 : width + (event.key === 'ArrowLeft' ? -16 : 16)); save();
  };
}
