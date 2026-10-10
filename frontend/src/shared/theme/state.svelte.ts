import { readPreference, writePreference } from '../utils/storage';
export class ThemeState {
  value = $state<'dark' | 'light'>(readPreference('musica:theme') === 'light' ? 'light' : 'dark');
  toggle(): void {
    this.value = this.value === 'dark' ? 'light' : 'dark';
    writePreference('musica:theme', this.value);
  }
}
