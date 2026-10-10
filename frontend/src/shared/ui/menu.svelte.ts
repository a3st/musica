export interface MenuItem {
  label: string;
  icon?: string;
  group?: string;
  hint?: string;
  action?: () => void;
  children?: MenuItem[];
  id?: string;
  disabled?: boolean;
  danger?: boolean;
}
export class MenuState {
  items = $state.raw<MenuItem[]>([]);
  opened = $state(false);
  origin = $state.raw<HTMLElement | null>(null);
  point = $state.raw<{ x: number; y: number } | null>(null);
  anchor = { x: 0, y: 0 };
  open(items: MenuItem[], origin: HTMLElement, point?: { x: number; y: number }): void {
    this.close(false);
    this.items = items;
    this.origin = origin;
    this.point = point ?? null;
    const rect = origin.getBoundingClientRect();
    this.anchor = { x: rect.left, y: rect.top };
    this.opened = true;
  }
  toggle(items: MenuItem[], origin: HTMLElement): void {
    if (this.opened && this.origin === origin) this.close();
    else this.open(items, origin);
  }
  close(focus = true): void {
    this.opened = false;
    if (focus && this.origin?.isConnected) this.origin.focus({ preventScroll: true });
  }
}
