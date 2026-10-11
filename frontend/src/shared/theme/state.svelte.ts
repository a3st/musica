import { readPreference, writePreference } from '../utils/storage';
export class ThemeState {
  value = $state<'dark' | 'light'>(readPreference('musica:theme') === 'light' ? 'light' : 'dark');
  toggle(): void {
    this.set(this.value === 'dark' ? 'light' : 'dark');
  }

  set(value: 'dark' | 'light'): void {
    this.value = value;
    writePreference('musica:theme', this.value);
  }
}
