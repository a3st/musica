import { t, msg, html, markup, initLocale, locale, setLocale } from './i18n';
import { registerSW } from 'virtual:pwa-register';
import { api, ApiError, errorMessage, type Playlist, type PlaylistSummary, type Track, type User } from './api';
import { escape, icon } from './icons';
import { Player } from './player';
import { Uploads } from './uploads';
import { SpotifyImporter } from './spotify-import';
import { initTheme } from './theme';
import { initCollectionScrollbar } from './scrollbar';
import { initSidebar } from './sidebar';
import { ContextMenu, type MenuItem } from './context-menu';
import { PlaylistEditor } from './playlist-editor';
import { playlistView } from './collection';
import { $, dialog, renderShell, welcome } from './view';
import './style.css';

renderShell();
initLocale();
initTheme();
initSidebar();
initCollectionScrollbar();
let user: User | null = null;
let playlists: PlaylistSummary[] = [];
let selected: Playlist | null = null;
let search = '';
let playlistSearch = '';
let version = 0;
let registering = false;
let toastTimer: ReturnType<typeof setTimeout>;
let playingCover: Playlist | null = null;
const shareLinks = new Map<string, string>();
const trackShareTokens = new Map<string, string>();
let selectedShareToken: string | null = null;
let player: Player;
function toast(message: string): void { clearTimeout(toastTimer); $('#toast').textContent = message; $('#toast').hidden = false; toastTimer = setTimeout(() => { $('#toast').hidden = true; }, 6000); }
function cover(playlist: Pick<Playlist, 'id' | 'image_key' | 'is_default'>, mini = false): string {
  if (playlist.image_key && (!selectedShareToken || playlists.some((p) => p.id === playlist.id))) return html`<img src="/api/playlists/${playlist.id}/image" alt="" loading="${mini ? 'lazy' : 'eager'}" />`;
  return html`<div class="cover-art ${playlist.is_default ? 'uploads-art' : 'mix-art'}" style="--hue:${parseInt(playlist.id.slice(0, 4), 16) % 80}">${icon(playlist.is_default ? 'upload' : 'music')}<span>${playlist.is_default ? 'UPLOADS' : 'MUSICA'}</span></div>`;
}
function writable(id: string): boolean { return playlists.some((p) => p.id === id && p.role !== 'viewer'); }
function renderSidebar(): void {
  const items = playlists.filter((p) => p.title.toLocaleLowerCase().includes(playlistSearch.toLocaleLowerCase())).map((p) => html`<button class="playlist-link ${selected?.id === p.id ? 'active' : ''}" data-playlist="${p.id}" title="${escape(p.title)}" aria-label="${escape(p.title)}" ${selected?.id === p.id ? 'aria-current="page"' : ''}><span class="nav-cover">${cover(p, true)}</span><span><strong>${escape(p.title)}</strong><small>${p.is_default ? t('Все ваши загрузки') : p.role !== 'owner' ? t('Общий плейлист') : msg`${p.track_count} треков`}</small></span></button>`).join('');
  document.querySelectorAll('.playlist-nav').forEach((node) => { node.innerHTML = items || html`<p class="nav-empty">${playlistSearch ? t('Плейлисты не найдены') : t('Ваши плейлисты появятся здесь')}</p>`; });
  document.querySelectorAll('.avatar-label').forEach((node) => { node.textContent = user?.username[0].toLocaleUpperCase() ?? 'M'; });
  document.querySelectorAll<HTMLButtonElement>('[data-action="logout"]').forEach((node) => { node.hidden = !user; });
}
function visibleTracks(): Track[] { return (selected?.tracks ?? []).filter((t) => `${t.title} ${t.artist}`.toLocaleLowerCase().includes(search.toLocaleLowerCase())); }
function renderCollection(): void {
  if (!selected) { $('#collection').innerHTML = welcome(); return; }
  const tracks = visibleTracks();
  $('#collection').innerHTML = playlistView(selected, tracks, user, player?.current?.id ?? null, writable(selected.id), search, cover(selected));
  $('#playlist-play').onclick = () => { const first = tracks.find((t) => t.status !== 'pending'); if (first) play(first); };
  $('#playlist-shuffle').onclick = () => { if ($('#shuffle').getAttribute('aria-pressed') !== 'true') $('#shuffle').click(); const playable = tracks.filter((t) => t.status !== 'pending'); if (playable.length) play(playable[Math.floor(Math.random() * playable.length)]); };
}
function playerChanged(): void {
  if (!player) return;
  $('.now-playing').hidden = !player.current;
  $('#now-title').textContent = player.current?.title ?? '';
  $('#now-artist').textContent = player.loading ? t('Готовим к воспроизведению…') : player.current?.artist ?? '';
  const key = player.current && playingCover ? playingCover.id : '';
  if ($('#now-art').dataset.art !== key) { $('#now-art').dataset.art = key; $('#now-art').innerHTML = player.current && playingCover ? cover(playingCover, true) : icon('music'); }
  renderQueue();
  document.querySelectorAll<HTMLElement>('[data-track-row]').forEach((row) => row.classList.toggle('is-playing', row.dataset.trackRow === player.current?.id));
}
player = new Player(playerChanged, toast, () => user?.id ?? null, (id) => trackShareTokens.get(id) ?? null);
const uploads = new Uploads(() => refresh(), toast);
const contextMenu = new ContextMenu();
const playlistEditor = new PlaylistEditor((id) => { shareLinks.delete(id); return refresh(id); }, toast);
const spotify = new SpotifyImporter((id) => refresh(id), () => user?.id ?? null);
const profileToggle = $('#profile-toggle');
const profileMenu = $('#profile-menu');
function closeProfile(): void { profileMenu.hidden = true; profileToggle.setAttribute('aria-expanded', 'false'); }
profileToggle.onclick = () => {
  profileMenu.hidden = !profileMenu.hidden;
  profileToggle.setAttribute('aria-expanded', String(!profileMenu.hidden));
};
document.addEventListener('click', (event) => { if (event.target instanceof Element && !event.target.closest('.profile')) closeProfile(); });
document.addEventListener('keydown', (event) => { if (event.key === 'Escape' && !profileMenu.hidden) { closeProfile(); profileToggle.focus(); } });
const language = $<HTMLSelectElement>('#language');
language.value = locale;
language.onchange = () => {
  setLocale(language.value);
};
window.addEventListener('localechange', () => { renderSidebar(); renderCollection(); playerChanged(); uploads.localize(); void spotify.localize(); });
function play(track: Track): void { playingCover = selected; void player.load(track, visibleTracks()); }
async function selectPlaylist(id: string, token: string | null = null): Promise<void> {
  const requestVersion = ++version;
  const playlist = token ? await api.sharedPlaylist(token) : await api.playlist(id);
  if (version !== requestVersion) return;
  selectedShareToken = token;
  if (token) for (const track of playlist.tracks) trackShareTokens.set(track.id, token);
  if (selected?.id !== id) { search = ''; $<HTMLInputElement>('#search').value = ''; $('#collection').scrollTop = 0; }
  selected = playlist; renderSidebar(); renderCollection(); document.title = `${playlist.title} · Musica`;
  const url = new URL(location.href); const publicLink = url.searchParams.get('playlist') === playlist.id; url.search = ''; url.hash = '';
  if (token) url.hash = 'share=' + token; else if (publicLink) url.searchParams.set('playlist', playlist.id);
  history.replaceState(null, '', url);
}
async function refresh(id?: string): Promise<void> {
  if (!user) return;
  playlists = await api.playlists();
  const candidate = id ?? selected?.id ?? user.default_playlist_id;
  if (!id && selectedShareToken) await selectPlaylist(candidate, selectedShareToken);
  else await selectPlaylist(playlists.some((p) => p.id === candidate) ? candidate : user.default_playlist_id);
}
async function openSession(): Promise<void> {
  const url = new URL(location.href); const token = new URLSearchParams(url.hash.slice(1)).get('share'); const id = url.searchParams.get('playlist');
  try { user = await api.me(); }
  catch (error) {
    if (!(error instanceof ApiError && error.status === 401 && (id || token))) throw error;
    user = null; playlists = [];
  }
  if (user) playlists = await api.playlists();
  if (token) { if (!/^[0-9a-f]{64}$/.test(token)) throw new Error(t('Некорректная ссылка')); await selectPlaylist('', token); }
  else if (id) { if (!/^[0-9a-f-]{36}$/i.test(id)) throw new Error(t('Некорректная ссылка')); await selectPlaylist(id); }
  else await refresh();
  dialog('auth-dialog').close(); if (user) await spotify.restore();
}
function requireLogin(): boolean { if (user) return true; dialog('auth-dialog').showModal(); return false; }
function clearSession(): void { player.stop(); uploads.reset(); spotify.reset(); shareLinks.clear(); trackShareTokens.clear(); selectedShareToken = null; user = null; selected = null; playlists = []; version++; renderSidebar(); renderCollection(); document.title = t('Musica · Ваша музыка'); }
document.addEventListener('error', (e) => { if (e.target instanceof HTMLImageElement) e.target.hidden = true; }, true);
document.addEventListener('click', (e) => {
  const target = e.target; if (!(target instanceof Element)) return;
  const close = target.closest('[data-close]'); if (close) { close.closest('dialog')?.close(); return; }
  const playlistButton = target.closest<HTMLElement>('[data-playlist]');
  if (playlistButton?.dataset.playlist) { dialog('library-dialog').close(); void selectPlaylist(playlistButton.dataset.playlist).catch((error: unknown) => toast(errorMessage(error))); return; }
  const playButton = target.closest<HTMLElement>('[data-play]');
  if (playButton?.dataset.play) { const track = selected?.tracks.find((t) => t.id === playButton.dataset.play); if (track) play(track); return; }
  const menu = target.closest<HTMLElement>('[data-track-menu]');
  if (menu?.dataset.trackMenu) { const track = selected?.tracks.find((t) => t.id === menu.dataset.trackMenu); if (track) showTrackMenu(track, menu); return; }
  const action = target.closest<HTMLElement>('[data-action]')?.dataset.action;
  if (action === 'login') dialog('auth-dialog').showModal();
  if (action === 'new-playlist' && requireLogin()) { void playlistEditor.open().catch((error: unknown) => toast(errorMessage(error))); }
  if (action === 'upload' && requireLogin()) { dialog('library-dialog').close(); uploads.open(); }
  if (action === 'spotify-import' && requireLogin()) { dialog('library-dialog').close(); dialog('upload-dialog').close(); spotify.open(); }
  if (action === 'logout') {
    if (uploads.busy) { toast(t('Сначала завершите загрузку или отмените её')); return; }
    void api.logout().then(() => { clearSession(); location.reload(); }).catch((error: unknown) => toast(errorMessage(error)));
  }
});
document.querySelectorAll('dialog').forEach((node) => node.addEventListener('click', (e) => { if (e.target === node) { const rect = node.getBoundingClientRect(); if (e.clientX < rect.left || e.clientX > rect.right || e.clientY < rect.top || e.clientY > rect.bottom) node.close(); } }));
$('#open-library').onclick = () => dialog('library-dialog').showModal();
$<HTMLInputElement>('#search').oninput = (e) => { search = (e.target as HTMLInputElement).value; renderCollection(); };
document.querySelectorAll<HTMLInputElement>('.playlist-search-input').forEach((input) => { input.oninput = () => {
  playlistSearch = input.value;
  document.querySelectorAll<HTMLInputElement>('.playlist-search-input').forEach((other) => { other.value = playlistSearch; });
  renderSidebar();
}; });
$('#auth-switch').onclick = () => {
  registering = !registering; $('#auth-title').innerHTML = registering ? markup('Музыка начинается<br>с вас<span>.</span>') : markup('Ваша музыка<br>всегда рядом<span>.</span>');
  $('#auth-submit').innerHTML = (registering ? t('Создать аккаунт ') : t('Войти ')) + icon('arrow'); $('#auth-switch').textContent = registering ? t('Уже есть аккаунт? Войти') : t('Нет аккаунта? Зарегистрироваться');
  $<HTMLInputElement>('#auth-form [name="password"]').autocomplete = registering ? 'new-password' : 'current-password'; $('#auth-error').textContent = '';
};
$<HTMLFormElement>('#auth-form').onsubmit = (e) => {
  e.preventDefault(); const form = e.currentTarget as HTMLFormElement; const data = new FormData(form); const button = $<HTMLButtonElement>('#auth-submit'); button.disabled = true; $('#auth-error').textContent = '';
  void (async () => { try { await api.signIn(String(data.get('username')), String(data.get('password')), registering); form.reset(); await openSession(); } catch (error) { $('#auth-error').textContent = error instanceof ApiError && error.status === 401 ? t('Неверное имя пользователя или пароль') : errorMessage(error); } finally { button.disabled = false; } })();
};
function confirmRemoval(title: string, description: string, remove: () => Promise<void>): void {
  $('#confirm-title').textContent = title; $('#confirm-description').textContent = description;
  dialog('confirm-dialog').showModal();
  $('#confirm-delete').onclick = () => {
    const button = $<HTMLButtonElement>('#confirm-delete'); button.disabled = true;
    void remove().then(() => dialog('confirm-dialog').close()).catch((error: unknown) => toast(errorMessage(error))).finally(() => { button.disabled = false; });
  };
}
function showPlaylistMenu(playlist: PlaylistSummary, origin: HTMLElement, point?: { x: number; y: number }): void {
  contextMenu.open([
    { label: t('Открыть плейлист'), icon: 'library', group: 'navigation', action: () => { dialog('library-dialog').close(); void selectPlaylist(playlist.id).catch((error: unknown) => toast(errorMessage(error))); } },
    { label: t('Редактировать плейлист'), icon: 'edit', group: 'settings', id: 'edit-playlist', disabled: playlist.is_default || playlist.role === 'viewer', hint: playlist.is_default ? t('Настройки Uploads нельзя изменять') : undefined, action: () => { void playlistEditor.open(playlist.id).catch((error: unknown) => toast(errorMessage(error))); } },
    { label: t('Копировать ссылку'), icon: 'link', group: 'sharing', id: 'share-playlist', disabled: playlist.is_default || playlist.visibility === 'private' || (playlist.visibility === 'unlisted' && playlist.role !== 'owner'), hint: playlist.visibility === 'private' ? t('Выберите публичный доступ или доступ по ссылке в настройках плейлиста') : undefined, action: () => { void copyShareLink(playlist).catch((error: unknown) => toast(errorMessage(error))); } },
    { label: playlist.is_default ? t('Uploads нельзя удалить') : t('Удалить плейлист'), icon: 'trash', group: 'danger', id: 'delete-playlist', danger: true, disabled: playlist.is_default || playlist.role !== 'owner', action: () => {
      dialog('library-dialog').close();
      confirmRemoval(t('Удалить плейлист?'), msg`«${playlist.title}» будет удалён. Треки останутся в Uploads и других плейлистах.`, async () => { await api.removePlaylist(playlist.id); await refresh(); toast(t('Плейлист удалён')); });
    } },
  ], origin, point);
}
async function copyShareLink(playlist: PlaylistSummary): Promise<void> {
  const url = new URL('/', location.origin);
  if (playlist.visibility === 'public') url.searchParams.set('playlist', playlist.id);
  else {
    let token = shareLinks.get(playlist.id);
    if (!token) { token = await api.createShareLink(playlist.id); shareLinks.set(playlist.id, token); }
    url.hash = 'share=' + token;
  }
  try { await navigator.clipboard.writeText(url.href); }
  catch {
    const input = document.createElement('textarea'); input.value = url.href; input.style.position = 'fixed'; input.style.opacity = '0'; document.body.append(input); input.select();
    try { if (!document.execCommand('copy')) throw new Error(t('Не удалось скопировать ссылку')); }
    finally { input.remove(); }
  }
  toast(t('Ссылка скопирована'));
}
function showTrackMenu(track: Track, origin: HTMLElement, point?: { x: number; y: number }): void {
  if (!selected) return;
  const playlist = selected;
  const targets = playlists.filter((item) => item.role !== 'viewer' && !item.is_default && item.id !== playlist.id);
  const items: MenuItem[] = [
    { label: t('Воспроизвести'), icon: 'play', group: 'playback', disabled: track.status === 'pending', action: () => play(track) },
    { label: t('Следующим в очереди'), icon: 'next', group: 'queue', disabled: track.status === 'pending', action: () => player.enqueue(track, true) },
    { label: t('Добавить в очередь'), icon: 'queue', group: 'queue', disabled: track.status === 'pending', action: () => player.enqueue(track) },
    { label: t('Добавить в другой плейлист'), icon: 'plus', group: 'organize', id: 'attach-track', disabled: track.owner_id !== user?.id || !targets.length, children: targets.map((target) => ({ label: target.title, icon: 'library', group: 'playlists', action: () => { void api.attachTrack(target.id, track.id).then(async () => { await refresh(); toast(t('Трек добавлен в плейлист')); }).catch((error: unknown) => toast(errorMessage(error))); } })) },
    { label: playlist.is_default ? t('Удалить из медиатеки') : t('Убрать из плейлиста'), icon: 'trash', group: 'danger', id: 'remove-track', danger: true, disabled: !writable(playlist.id), action: () => {
      const title = playlist.is_default ? t('Удалить трек навсегда?') : t('Убрать трек из плейлиста?');
      const description = playlist.is_default ? msg`«${track.title}» будет удалён из медиатеки и всех плейлистов. Файл и готовые сегменты также будут удалены.` : msg`«${track.title}» останется в Uploads и других плейлистах.`;
      confirmRemoval(title, description, async () => {
        if (playlist.is_default) { await api.removeTrack(track.id); player.remove(track.id); } else await api.detachTrack(playlist.id, track.id);
        await refresh(); toast(playlist.is_default ? t('Трек удалён из медиатеки') : t('Трек убран из плейлиста'));
      });
    } },
  ];
  if (point) contextMenu.open(items, origin, point); else contextMenu.toggle(items, origin);
}
document.addEventListener('contextmenu', (event) => {
  if (!(event.target instanceof Element)) return;
  const row = event.target.closest<HTMLElement>('[data-track-row]');
  const playlistButton = event.target.closest<HTMLElement>('[data-playlist], [data-playlist-context]');
  if (row) { const track = selected?.tracks.find((item) => item.id === row.dataset.trackRow); if (track) { event.preventDefault(); showTrackMenu(track, row, { x: event.clientX, y: event.clientY }); } }
  else if (playlistButton) {
    const id = playlistButton.dataset.playlist ?? playlistButton.dataset.playlistContext;
    const playlist = playlists.find((item) => item.id === id) ?? (selected && selected.id === id ? { ...selected, role: 'viewer' as const, track_count: selected.tracks.length } : null);
    if (playlist) { event.preventDefault(); showPlaylistMenu(playlist, playlistButton, { x: event.clientX, y: event.clientY }); }
  }
});
function renderQueue(): void {
  if (!player) return;
  const row = (track: Track, current = false) => html`<div class="queue-item ${current ? 'queue-current' : ''}"><button class="queue-track" data-queue-play="${track.id}"><span class="track-art">${icon(current ? 'play' : 'music')}</span><span><strong>${escape(track.title)}</strong><small>${escape(track.artist)}</small></span></button>${current ? '' : html`<button class="icon-button" data-queue-remove="${track.id}" aria-label="Убрать из очереди">${icon('close')}</button>`}</div>`;
  $('#queue-list').innerHTML = player.current ? html`<h3>Сейчас играет</h3>${row(player.current, true)}<h3>Далее</h3>${player.upcoming.map((track) => row(track)).join('') || html`<p class="muted">Очередь пуста</p>`}` : html`<p class="muted">Выберите трек или добавьте его в очередь.</p>`;
}
function closeQueue(): void { $('#app').classList.remove('queue-open'); $('#queue-panel').classList.remove('open'); $('#queue-panel').inert = true; $('#queue-toggle').setAttribute('aria-expanded', 'false'); }
$('#queue-toggle').setAttribute('aria-controls', 'queue-panel'); $('#queue-toggle').setAttribute('aria-expanded', 'false');
$('#queue-toggle').onclick = () => { const panel = $('#queue-panel'); if (panel.classList.contains('open')) closeQueue(); else { renderQueue(); $('#app').classList.add('queue-open'); panel.inert = false; panel.classList.add('open'); $('#queue-toggle').setAttribute('aria-expanded', 'true'); } };
$('#queue-close').onclick = () => { closeQueue(); $('#queue-toggle').focus(); };
$('#queue-list').onclick = (event) => { if (!(event.target instanceof Element)) return; const button = event.target.closest<HTMLElement>('[data-queue-play],[data-queue-remove]'); if (button?.dataset.queuePlay) player.playQueued(button.dataset.queuePlay); if (button?.dataset.queueRemove) player.removeQueued(button.dataset.queueRemove); };
document.addEventListener('keydown', (event) => { if (!event.defaultPrevented && event.key === 'Escape' && $('#queue-panel').classList.contains('open')) closeQueue(); });
let polling = false;
setInterval(() => {
  if (!user || !navigator.onLine || document.hidden || polling) return;
  polling = true;
  void (async () => {
    try {
      await uploads.poll();
      await spotify.poll();
      if (selected?.tracks.some((t) => t.status !== 'streamed')) {
        const id = selected.id; const requestVersion = version; const updated = selectedShareToken ? await api.sharedPlaylist(selectedShareToken) : await api.playlist(id);
        if (selected?.id === id && version === requestVersion && JSON.stringify(updated.tracks) !== JSON.stringify(selected.tracks)) { selected = updated; renderCollection(); }
      }
    } catch (error) { if (error instanceof ApiError && error.status === 401) { clearSession(); toast(t('Сессия завершилась. Войдите снова.')); dialog('auth-dialog').showModal(); } }
    finally { polling = false; }
  })();
}, 5000);
function connection(): void { $('#connection').hidden = navigator.onLine; }
window.addEventListener('online', () => { connection(); if (user) void refresh().catch((error: unknown) => toast(errorMessage(error))); });
window.addEventListener('offline', connection); connection();
const updateSW = registerSW({ onNeedRefresh: () => { $('#update').hidden = false; }, onRegisterError: (error: unknown) => console.error('Service worker registration failed', error) });
$('#update').onclick = () => { if (uploads.busy) toast(t('Сначала завершите загрузку')); else void updateSW(true); };
void openSession().catch((error: unknown) => { if (!(error instanceof ApiError && error.status === 401)) toast(errorMessage(error)); renderSidebar(); dialog('auth-dialog').showModal(); });
window.addEventListener('hashchange', () => { void openSession().catch((error: unknown) => toast(errorMessage(error))); });
