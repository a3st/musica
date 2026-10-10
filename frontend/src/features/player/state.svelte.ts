import { PlayerEngine } from './engine';
import type { Playlist } from '../playlists/model';
export class PlayerState {
  value = $state<ReturnType<PlayerEngine['snapshot']>>({
    current: null,
    loading: false,
    upcoming: [],
    paused: true,
    elapsed: 0,
    duration: 0,
    volume: 100,
    muted: false,
    shuffle: false,
    repeat: 'none',
  });
  cover = $state<Playlist | null>(null);
  queueOpen = $state(false);
  readonly engine: PlayerEngine;
  constructor(
    notify: (message: string) => void,
    userId: () => string | null,
    shareToken: (id: string) => string | null,
  ) {
    this.engine = new PlayerEngine(
      () => {
        this.value = this.engine.snapshot();
      },
      notify,
      userId,
      shareToken,
    );
  }
  dispose(): void {
    this.engine.dispose();
  }
}
