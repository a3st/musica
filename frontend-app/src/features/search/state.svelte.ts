import { tracksApi } from '../tracks/api';
import type { LibraryMatch, Track } from '../tracks/model';
import type { SearchTrack } from '../web-search/model';
import { searchTrackKey } from '../web-search/model';
import { WebSearchState } from '../web-search/state.svelte';
import { errorMessage } from '../../shared/api/errors';

/** Локальный результат использует проверенную модель поиска по пользовательским трекам. */
export type LocalResult = LibraryMatch;

export type RecentResult =
  | { kind: 'local'; result: LocalResult }
  | { kind: 'service'; track: Track }
  | { kind: 'web'; track: SearchTrack };

/** Ищет пользовательские треки в доступных плейлистах, затем сервисные треки и каталог. */
export class SearchState {
  readonly web: WebSearchState;
  query = $state('');
  open = $state(false);
  loading = $state(false);
  searched = $state(false);
  error = $state('');
  local = $state<LocalResult[]>([]);
  service = $state<Track[]>([]);
  serviceAdditions = $state<Record<string, 'adding' | 'added'>>({});
  recent = $state<RecentResult[]>([]);
  private timer?: ReturnType<typeof setTimeout>;
  private controller?: AbortController;
  private version = 0;

  /** Подключает каталог с проверкой доступности поиска и обновлением библиотеки. */
  constructor(
    private readonly canSearchWeb: () => boolean,
    refresh: () => Promise<void>,
  ) {
    this.web = new WebSearchState(refresh);
  }

  /** Сбрасывает выдачу и запускает поиск с задержкой, отменяя прежние запросы. */
  setQuery(query: string): void {
    this.cancel();
    this.query = query;
    this.open = true;
    this.local = [];
    this.service = [];
    this.error = '';
    this.searched = false;
    this.web.setQuery(query);
    if (query.trim()) {
      this.loading = true;
      this.timer = setTimeout(() => void this.search(), 350);
    }
  }

  /** Ищет личные треки; при отсутствии совпадений обращается к сервисным трекам и каталогу. */
  async search(): Promise<void> {
    this.cancel();
    const query = this.query.trim();
    if (!query) return;

    this.open = true;
    this.loading = true;
    this.searched = true;
    this.error = '';
    this.local = [];
    this.service = [];
    this.web.setQuery(query);
    const version = this.version;
    const controller = new AbortController();
    this.controller = controller;

    try {
      if (query.length < 2 || new TextEncoder().encode(query).length > 256) return;

      const matches = await tracksApi.searchLibrary(query, controller.signal);
      if (version !== this.version) return;

      this.local = matches;
      if (!matches.length && this.canSearchWeb()) {
        await this.web.search();
        if (version !== this.version) return;

        this.service = this.web.library;
      }
    } catch (error) {
      if (version === this.version && !controller.signal.aborted) {
        this.error = errorMessage(error);
        controller.abort();
      }
    } finally {
      if (version === this.version) this.loading = false;
    }
  }

  /** Сохраняет до восьми недавних результатов без повторов по идентификатору. */
  remember(result: RecentResult): void {
    const key = (item: RecentResult) =>
      item.kind === 'web'
        ? `web:${searchTrackKey(item.track)}`
        : `track:${item.kind === 'local' ? item.result.track.id : item.track.id}`;
    this.recent = [result, ...this.recent.filter((item) => key(item) !== key(result))].slice(0, 8);
  }

  /** Закрывает выдачу и отменяет незавершённый поиск. */
  close(): void {
    this.open = false;
    if (this.loading) this.searched = false;
    this.cancel();
  }

  /** Отменяет задержку и запросы обоих уровней поиска, инвалидируя ответы. */
  private cancel(): void {
    clearTimeout(this.timer);
    this.timer = undefined;
    this.version++;
    this.controller?.abort();
    this.controller = undefined;
    this.web.cancelSearch();
    this.loading = false;
  }

  /** Очищает выдачу, недавние результаты и состояние добавления при смене сессии. */
  reset(): void {
    this.close();
    this.web.reset();
    this.query = '';
    this.local = [];
    this.service = [];
    this.serviceAdditions = {};
    this.recent = [];
    this.error = '';
    this.searched = false;
  }
}
