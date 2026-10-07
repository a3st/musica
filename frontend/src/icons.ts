const paths: Record<string, string> = {
  music: '<path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/>',
  search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  upload: '<path d="M12 16V3m-5 5 5-5 5 5M4 16v5h16v-5"/>',
  play: '<path d="m9 5 11 7-11 7z" fill="currentColor" stroke="none"/>',
  pause: '<path d="M8 5v14M16 5v14" stroke-width="4"/>',
  next: '<path d="m5 5 10 7-10 7z" fill="currentColor" stroke="none"/><path d="M19 5v14"/>',
  previous: '<path d="m19 5-10 7 10 7z" fill="currentColor" stroke="none"/><path d="M5 5v14"/>',
  shuffle: '<path d="M3 6h3l12 12h3m-4-4 4 4-4 4M3 18h3l4-4m4-4 4-4h3m-4-4 4 4-4 4"/>',
  repeat: '<path d="m16 2 4 4-4 4M4 11V8a2 2 0 0 1 2-2h14M8 22l-4-4 4-4m12-1v3a2 2 0 0 1-2 2H4"/>',
  volume: '<path d="M3 9h4l5-4v14l-5-4H3zM16 8a6 6 0 0 1 0 8m3-11a10 10 0 0 1 0 14"/>',
  more: '<circle cx="5" cy="12" r="1" fill="currentColor"/><circle cx="12" cy="12" r="1" fill="currentColor"/><circle cx="19" cy="12" r="1" fill="currentColor"/>',
  close: '<path d="m6 6 12 12M6 18 18 6"/>',
  library: '<path d="M4 4v16M9 4v16m5-16 6 15M3 8h7"/>',
  arrow: '<path d="M5 12h14m-6-6 6 6-6 6"/>',
  trash: '<path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7m4-7v7"/>',
  refresh: '<path d="M20 7v5h-5M4 17v-5h5M6 6a8 8 0 0 1 14 6M4 12a8 8 0 0 0 14 6"/>',
  logout: '<path d="M10 4H4v16h6m5-12 4 4-4 4M9 12h10"/>',
  check: '<path d="m5 12 4 4L19 6"/>',
  lock: '<rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/>',
};
export function icon(name: string): string { return `<svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">${paths[name] ?? paths.music}</svg>`; }
export function escape(value: string): string { return value.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!)); }
export function time(seconds: number): string { if (!Number.isFinite(seconds) || seconds < 0) return '0:00'; return `${Math.floor(seconds / 60)}:${Math.floor(seconds % 60).toString().padStart(2, '0')}`; }
