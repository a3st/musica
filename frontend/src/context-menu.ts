import { icon } from './icons';
export interface MenuItem { label: string; icon?: string; group?: string; hint?: string; action?: () => void; children?: MenuItem[]; id?: string; disabled?: boolean; danger?: boolean }
export class ContextMenu {
  private readonly element = document.querySelector<HTMLElement>('#context-menu')!;
  private origin: HTMLElement | null = null;
  private readonly submenu = document.createElement('div');
  private submenuOrigin: HTMLButtonElement | null = null;
  private readonly children = new Map<HTMLButtonElement, MenuItem[]>();
  private anchor = { x: 0, y: 0 };
  constructor() {
    this.submenu.id = 'context-submenu'; this.submenu.role = 'menu'; this.submenu.className = 'context-menu context-submenu'; this.submenu.hidden = true;
    document.addEventListener('pointerdown', (event) => {
      if (!(event.target instanceof Node) || this.contains(event.target)) return;
      if (event.button === 0 && this.origin?.matches('[data-track-menu]') && this.origin.contains(event.target)) return;
      this.close(false);
    });
    document.addEventListener('keydown', (event) => {
      if (this.element.hidden) return;
      if (event.key === 'Escape') { event.preventDefault(); if (!this.submenu.hidden) this.closeSubmenu(true); else this.close(); }
      if (event.key === 'Tab') this.close(false);
      if (event.key === 'ArrowRight' && document.activeElement instanceof HTMLButtonElement) {
        const items = this.children.get(document.activeElement);
        if (items) { event.preventDefault(); this.openSubmenu(items, document.activeElement, true); }
      }
      if (event.key === 'ArrowLeft' && !this.submenu.hidden) { event.preventDefault(); this.closeSubmenu(true); }
      if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
        event.preventDefault();
        const menu = this.submenu.contains(document.activeElement) ? this.submenu : this.element;
        const buttons = [...menu.querySelectorAll<HTMLButtonElement>('button:not(:disabled)')];
        const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
        const next = event.key === 'Home' ? 0 : event.key === 'End' ? buttons.length - 1 : (index + (event.key === 'ArrowDown' ? 1 : -1) + buttons.length) % buttons.length;
        buttons[next]?.focus();
      }
    });
    window.addEventListener('resize', () => this.close(false));
    document.addEventListener('scroll', (event) => {
      if (this.element.hidden || !(event.target instanceof Node) || this.contains(event.target)) return;
      const rect = this.origin?.getBoundingClientRect();
      // A click can open the menu before the trigger's earlier scroll event is delivered.
      if (!rect || Math.abs(rect.left - this.anchor.x) > .5 || Math.abs(rect.top - this.anchor.y) > .5) this.close(false);
    }, true);
    window.addEventListener('localechange', () => this.close(false));
  }
  private contains(node: Node): boolean { return this.element.contains(node) || this.submenu.contains(node); }
  private closeSubmenu(focus = false): void {
    this.submenu.hidden = true; this.submenuOrigin?.setAttribute('aria-expanded', 'false');
    if (focus) this.submenuOrigin?.focus({ preventScroll: true }); this.submenuOrigin = null;
    this.element.style.maxHeight = '';
  }
  close(focus = true): void { this.closeSubmenu(); this.element.hidden = true; if (this.origin?.matches('[data-track-menu]')) this.origin.setAttribute('aria-expanded', 'false'); if (focus && this.origin?.isConnected) this.origin.focus({ preventScroll: true }); }
  toggle(items: MenuItem[], origin: HTMLElement): void {
    if (!this.element.hidden && this.origin === origin) this.close(); else this.open(items, origin);
  }
  open(items: MenuItem[], origin: HTMLElement, point?: { x: number; y: number }): void {
    this.close(false); this.children.clear();
    (origin.closest('dialog') ?? document.querySelector('#app')!).append(this.element, this.submenu);
    this.origin = origin; this.render(items, this.element);
    if (origin.matches('[data-track-menu]')) { origin.setAttribute('aria-haspopup', 'menu'); origin.setAttribute('aria-expanded', 'true'); }
    this.element.hidden = false;
    const anchor = origin.getBoundingClientRect(); const rect = this.element.getBoundingClientRect();
    this.anchor = { x: anchor.left, y: anchor.top };
    this.element.style.left = `${Math.max(8, Math.min(point?.x ?? anchor.left, window.innerWidth - rect.width - 8))}px`;
    const top = point?.y ?? (anchor.bottom + rect.height + 4 <= window.innerHeight - 8 ? anchor.bottom + 4 : anchor.top - rect.height - 4);
    this.element.style.top = `${Math.max(8, Math.min(top, window.innerHeight - rect.height - 8))}px`;
    this.element.querySelector<HTMLButtonElement>('button:not(:disabled)')?.focus({ preventScroll: true });
  }
  private render(items: MenuItem[], menu: HTMLElement): void {
    menu.replaceChildren();
    let group: string | undefined;
    for (const item of items) {
      if (menu.childElementCount && item.group !== group) {
        const separator = document.createElement('div'); separator.role = 'separator'; separator.className = 'context-menu-separator'; menu.append(separator);
      }
      group = item.group;
      const button = document.createElement('button'); button.type = 'button'; button.role = 'menuitem';
      button.innerHTML = icon(item.icon ?? 'music');
      const label = document.createElement('span'); label.textContent = item.label; button.append(label);
      button.disabled = item.disabled ?? (!item.action && !item.children?.length);
      if (item.hint) button.title = item.hint;
      if (item.id) button.id = item.id;
      button.className = 'context-menu-item' + (item.danger ? ' danger-item' : '');
      if (item.children?.length) {
        this.children.set(button, item.children);
        button.insertAdjacentHTML('beforeend', icon('chevron-right'));
        button.setAttribute('aria-haspopup', 'menu'); button.setAttribute('aria-expanded', 'false'); button.setAttribute('aria-controls', 'context-submenu');
        button.onpointerenter = () => { if (!button.disabled) this.openSubmenu(item.children!, button); };
        button.onclick = () => this.openSubmenu(item.children!, button, true);
      } else {
        if (menu === this.element) button.onpointerenter = () => this.closeSubmenu();
        button.onclick = () => { this.close(); item.action?.(); };
      }
      menu.append(button);
    }
  }
  private openSubmenu(items: MenuItem[], origin: HTMLButtonElement, focus = false): void {
    if (this.submenuOrigin !== origin) {
      this.closeSubmenu(); this.submenuOrigin = origin; this.render(items, this.submenu);
      this.submenu.setAttribute('aria-label', origin.textContent ?? '');
    }
    this.submenu.hidden = false; this.submenu.style.maxHeight = ''; origin.setAttribute('aria-expanded', 'true');
    let parent = this.element.getBoundingClientRect(); const rect = this.submenu.getBoundingClientRect(); const anchor = origin.getBoundingClientRect();
    let left: number; let top = Math.max(8, Math.min(anchor.top - 7, window.innerHeight - rect.height - 8));
    if (parent.right + rect.width + 4 <= window.innerWidth - 8) left = parent.right + 4;
    else if (parent.left - rect.width - 4 >= 8) left = parent.left - rect.width - 4;
    else {
      // Narrow screens keep both menus visible by stacking the child below its parent.
      this.element.style.maxHeight = `${(window.innerHeight - 28) / 2}px`; this.element.style.top = '8px'; parent = this.element.getBoundingClientRect();
      left = Math.max(8, Math.min(parent.left, window.innerWidth - rect.width - 8)); top = parent.bottom + 4;
      this.submenu.style.maxHeight = `${window.innerHeight - top - 8}px`;
    }
    this.submenu.style.left = `${left}px`; this.submenu.style.top = `${top}px`;
    if (focus) this.submenu.querySelector<HTMLButtonElement>('button:not(:disabled)')?.focus({ preventScroll: true });
  }
}
