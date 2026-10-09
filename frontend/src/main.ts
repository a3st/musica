import { registerSW } from 'virtual:pwa-register';
import { api, ApiError, errorMessage, type Playlist, type PlaylistSummary, type Track, type User } from './api';
import { escape, icon } from './icons';
import { Player } from './player';
import { Uploads } from './uploads';
import { SpotifyImporter } from './spotify-import';
import { $, dialog, renderShell, welcome } from './view';
import './style.css';

renderShell();
let user: User | null = null;
let playlists: PlaylistSummary[] = [];
let selected: Playlist | null = null;
let search = '';
let version = 0;
let registering = false;
let toastTimer: ReturnType<typeof setTimeout>;
let playingCover: Playlist | null = null;
let player: Player;
function toast(message: string): void { clearTimeout(toastTimer); $('#toast').textContent = message; $('#toast').hidden = false; toastTimer = setTimeout(() => { $('#toast').hidden = true; }, 6000); }
function cover(playlist: Pick<Playlist, 'id' | 'image_key' | 'is_default'>, mini = false): string {
  if (playlist.image_key) return `<img src="/api/playlists/${playlist.id}/image" alt="" loading="${mini ? 'lazy' : 'eager'}" />`;
  return `<div class="cover-art ${playlist.is_default ? 'uploads-art' : 'mix-art'}" style="--hue:${parseInt(playlist.id.slice(0, 4), 16) % 80}">${icon(playlist.is_default ? 'upload' : 'music')}<span>${playlist.is_default ? 'UPLOADS' : 'MUSICA'}</span></div>`;
}
function writable(id: string): boolean { return playlists.some((p) => p.id === id && p.role !== 'viewer'); }
function renderSidebar(): void {
  const items = playlists.map((p) => `<button class="playlist-link ${selected?.id === p.id ? 'active' : ''}" data-playlist="${p.id}" ${selected?.id === p.id ? 'aria-current="page"' : ''}><span class="nav-cover">${cover(p, true)}</span><span><strong>${escape(p.title)}</strong><small>${p.is_default ? 'Все ваши загрузки' : p.role !== 'owner' ? 'Общий плейлист' : `${p.track_count} треков`}</small></span></button>`).join('');
  document.querySelectorAll('.playlist-nav').forEach((node) => { node.innerHTML = items || '<p class="nav-empty">Ваши плейлисты появятся здесь</p>'; });
  $('#user-name').textContent = user?.username ?? 'Ваша коллекция';
  document.querySelectorAll<HTMLButtonElement>('[data-action="logout"]').forEach((node) => { node.hidden = !user; });
}
function visibleTracks(): Track[] { return (selected?.tracks ?? []).filter((t) => `${t.title} ${t.artist}`.toLocaleLowerCase().includes(search.toLocaleLowerCase())); }
function renderCollection(): void {
  if (!selected) { $('#collection').innerHTML = welcome; return; }
  const tracks = visibleTracks();
  const visibility = selected.is_default ? 'Ваша библиотека' : { private: 'Приватный плейлист', public: 'Публичный плейлист', unlisted: 'Доступ по ссылке' }[selected.visibility];
  $('#collection').innerHTML = `<section class="playlist-hero"><div class="hero-cover">${cover(selected)}</div><div class="hero-text"><span class="eyebrow">${escape(visibility)}</span><h1>${escape(selected.title)}</h1><p>${escape(selected.description || (selected.is_default ? 'Всё, что вы загрузили. Всегда под рукой.' : 'Своя музыка для своего настроения.'))}</p><div class="hero-facts"><span class="owner-dot"></span><strong>${selected.owner_id === user?.id ? escape(user.username) : 'Общий плейлист'}</strong><span>·</span><span>${selected.tracks.length} треков</span></div></div></section><div class="collection-toolbar"><button class="button primary playlist-play" id="playlist-play" ${tracks.some((t) => t.status !== 'pending') ? '' : 'disabled'}>${icon('play')} Слушать</button><span class="collection-label">${search ? `${tracks.length} найдено` : 'Треки в плейлисте'}</span><span class="collection-note">${icon('lock')} ${selected.is_default ? 'Только вы' : selected.visibility === 'private' ? 'Приватный' : selected.visibility === 'public' ? 'Публичный' : 'По ссылке'}</span></div><div class="track-table"><div class="track-table-heading"><span>#</span><span>НАЗВАНИЕ</span><span>ИСПОЛНИТЕЛЬ</span><span>ГОТОВНОСТЬ</span><span></span></div>${tracks.map((t, index) => `<div class="track-row ${player?.current?.id === t.id ? 'is-playing' : ''}" data-track-row="${t.id}"><button class="track-play" data-play="${t.id}" aria-label="Воспроизвести ${escape(t.title)}" ${t.status === 'pending' ? 'disabled' : ''}><span class="track-index">${index + 1}</span><span class="row-play-icon">${icon('play')}</span></button><div class="track-title"><strong>${escape(t.title)}</strong><span>${escape(t.artist)}</span></div><span class="track-artist">${escape(t.artist)}</span><span class="track-status ${t.status === 'streamed' ? 'ready-status' : ''}">${t.status === 'streamed' ? '<i></i> Готов' : t.status === 'ready' ? 'Подготовка' : 'Нет файла'}</span><button class="icon-button track-more" data-track-menu="${t.id}" aria-label="Действия с треком ${escape(t.title)}">${icon('more')}</button></div>`).join('')}${!tracks.length ? `<div class="empty-state"><div class="empty-icon">${icon(search ? 'search' : 'music')}</div><h2>${search ? 'Ничего не нашлось' : 'Начните свою коллекцию'}</h2><p>${search ? 'Попробуйте другое название или исполнителя.' : 'Добавьте музыку — и здесь появятся ваши треки.'}</p>${!search && writable(selected.id) ? '<button class="button secondary desktop-only" data-action="upload">Загрузить треки</button>' : ''}</div>` : ''}</div>`;
  $('#playlist-play').onclick = () => { const first = tracks.find((t) => t.status !== 'pending'); if (first) play(first); };
}
function playerChanged(): void {
  if (!player) return;
  $('#now-title').textContent = player.current?.title ?? 'Выберите трек';
  $('#now-artist').textContent = player.loading ? 'Готовим к воспроизведению…' : player.current?.artist ?? 'Музыка ждёт своего момента';
  const key = player.current && playingCover ? playingCover.id : '';
  if ($('#now-art').dataset.art !== key) { $('#now-art').dataset.art = key; $('#now-art').innerHTML = player.current && playingCover ? cover(playingCover, true) : icon('music'); }
  document.querySelectorAll<HTMLElement>('[data-track-row]').forEach((row) => row.classList.toggle('is-playing', row.dataset.trackRow === player.current?.id));
}
player = new Player(playerChanged, toast, () => user?.id ?? null);
const uploads = new Uploads(() => ({ playlists, selected: selected?.id ?? null, defaultId: user?.default_playlist_id ?? null }), () => refresh(), toast);
const spotify = new SpotifyImporter((id) => refresh(id), () => user?.id ?? null);
function play(track: Track): void { playingCover = selected; void player.load(track, visibleTracks()); }
async function selectPlaylist(id: string): Promise<void> {
  const requestVersion = ++version; $('#refresh').setAttribute('aria-busy', 'true');
  try {
    const playlist = await api.playlist(id);
    if (version !== requestVersion || !user) return;
    if (selected?.id !== id) { search = ''; $<HTMLInputElement>('#search').value = ''; }
    selected = playlist; renderSidebar(); renderCollection(); document.title = `${playlist.title} · Musica`;
  } finally { if (version === requestVersion) $('#refresh').removeAttribute('aria-busy'); }
}
async function refresh(id?: string): Promise<void> {
  if (!user) return;
  playlists = await api.playlists();
  const candidate = id ?? selected?.id ?? user.default_playlist_id;
  await selectPlaylist(playlists.some((p) => p.id === candidate) ? candidate : user.default_playlist_id);
}
async function openSession(): Promise<void> { user = await api.me(); await refresh(); dialog('auth-dialog').close(); await spotify.restore(); }
function requireLogin(): boolean { if (user) return true; dialog('auth-dialog').showModal(); return false; }
function clearSession(): void { player.stop(); uploads.reset(); spotify.reset(); user = null; selected = null; playlists = []; version++; renderSidebar(); renderCollection(); document.title = 'Musica · Ваша музыка'; }
document.addEventListener('error', (e) => { if (e.target instanceof HTMLImageElement) e.target.hidden = true; }, true);
document.addEventListener('click', (e) => {
  const target = e.target; if (!(target instanceof Element)) return;
  const close = target.closest('[data-close]'); if (close) { close.closest('dialog')?.close(); return; }
  const playlistButton = target.closest<HTMLElement>('[data-playlist]');
  if (playlistButton?.dataset.playlist) { dialog('library-dialog').close(); void selectPlaylist(playlistButton.dataset.playlist).catch((error: unknown) => toast(errorMessage(error))); return; }
  const playButton = target.closest<HTMLElement>('[data-play]');
  if (playButton?.dataset.play) { const track = selected?.tracks.find((t) => t.id === playButton.dataset.play); if (track) play(track); return; }
  const menu = target.closest<HTMLElement>('[data-track-menu]');
  if (menu?.dataset.trackMenu) { const track = selected?.tracks.find((t) => t.id === menu.dataset.trackMenu); if (track) showTrackActions(track); return; }
  const action = target.closest<HTMLElement>('[data-action]')?.dataset.action;
  if (action === 'login') dialog('auth-dialog').showModal();
  if (action === 'new-playlist' && requireLogin()) { dialog('library-dialog').close(); dialog('playlist-dialog').showModal(); }
  if (action === 'upload' && requireLogin()) uploads.open();
  if (action === 'spotify-import' && requireLogin()) { dialog('library-dialog').close(); spotify.open(); }
  if (action === 'logout') {
    if (uploads.busy) { toast('Сначала завершите загрузку или отмените её'); return; }
    void api.logout().then(() => { clearSession(); location.reload(); }).catch((error: unknown) => toast(errorMessage(error)));
  }
});
document.querySelectorAll('dialog').forEach((node) => node.addEventListener('click', (e) => { if (e.target === node) { const rect = node.getBoundingClientRect(); if (e.clientX < rect.left || e.clientX > rect.right || e.clientY < rect.top || e.clientY > rect.bottom) node.close(); } }));
$('#open-library').onclick = () => dialog('library-dialog').showModal();
$('#refresh').onclick = () => { if (requireLogin()) void refresh().catch((error: unknown) => toast(errorMessage(error))); };
$<HTMLInputElement>('#search').oninput = (e) => { search = (e.target as HTMLInputElement).value; renderCollection(); };
$('#auth-switch').onclick = () => {
  registering = !registering; $('#auth-title').innerHTML = registering ? 'Музыка начинается<br>с вас<span>.</span>' : 'Ваша музыка<br>всегда рядом<span>.</span>';
  $('#auth-submit').innerHTML = (registering ? 'Создать аккаунт ' : 'Войти ') + icon('arrow'); $('#auth-switch').textContent = registering ? 'Уже есть аккаунт? Войти' : 'Нет аккаунта? Зарегистрироваться';
  $<HTMLInputElement>('#auth-form [name="password"]').autocomplete = registering ? 'new-password' : 'current-password'; $('#auth-error').textContent = '';
};
$<HTMLFormElement>('#auth-form').onsubmit = (e) => {
  e.preventDefault(); const form = e.currentTarget as HTMLFormElement; const data = new FormData(form); const button = $<HTMLButtonElement>('#auth-submit'); button.disabled = true; $('#auth-error').textContent = '';
  void (async () => { try { await api.signIn(String(data.get('username')), String(data.get('password')), registering); form.reset(); await openSession(); } catch (error) { $('#auth-error').textContent = error instanceof ApiError && error.status === 401 ? 'Неверное имя пользователя или пароль' : errorMessage(error); } finally { button.disabled = false; } })();
};
$<HTMLFormElement>('#playlist-form').onsubmit = (e) => {
  e.preventDefault(); const form = e.currentTarget as HTMLFormElement; const data = new FormData(form); const button = form.querySelector<HTMLButtonElement>('button')!; button.disabled = true;
  form.querySelector<HTMLElement>('.form-error')!.textContent = '';
  void (async () => { try { const id = await api.createPlaylist(String(data.get('title')).trim(), String(data.get('description')).trim(), data.get('visibility') as Playlist['visibility']); await refresh(id); dialog('playlist-dialog').close(); form.reset(); toast('Плейлист создан'); } catch (error) { form.querySelector<HTMLElement>('.form-error')!.textContent = errorMessage(error); } finally { button.disabled = false; } })();
};
function showTrackActions(track: Track): void {
  if (!selected) return;
  $('#track-action-title').textContent = track.title;
  const targets = playlists.filter((p) => p.role !== 'viewer' && !p.is_default && p.id !== selected?.id);
  $('#track-actions').innerHTML = `${track.owner_id === user?.id ? `<label>Добавить в другой плейлист<select id="attach-target">${targets.map((p) => `<option value="${p.id}">${escape(p.title)}</option>`).join('')}</select></label><button class="button secondary wide" id="attach-track" ${targets.length ? '' : 'disabled'}>${icon('plus')} Добавить</button>` : ''}${writable(selected.id) ? `<button class="text-button delete-track" id="remove-track">${icon('trash')} ${selected.is_default ? 'Удалить из медиатеки' : 'Убрать из плейлиста'}</button>` : '<p class="muted">Доступ к плейлисту только для просмотра.</p>'}`;
  const attach = document.querySelector<HTMLButtonElement>('#attach-track');
  if (attach) attach.onclick = () => { attach.disabled = true; void api.attachTrack($<HTMLSelectElement>('#attach-target').value, track.id).then(async () => { dialog('track-dialog').close(); await refresh(); toast('Трек добавлен в плейлист'); }).catch((error: unknown) => { attach.disabled = false; toast(errorMessage(error)); }); };
  const remove = document.querySelector<HTMLButtonElement>('#remove-track');
  if (remove) remove.onclick = () => {
    const playlist = selected!; dialog('track-dialog').close();
    $('#confirm-title').textContent = playlist.is_default ? 'Удалить трек навсегда?' : 'Убрать трек из плейлиста?';
    $('#confirm-description').textContent = playlist.is_default ? `«${track.title}» будет удалён из медиатеки и всех плейлистов. Файл и готовые сегменты также будут удалены.` : `«${track.title}» останется в Uploads и других плейлистах.`;
    dialog('confirm-dialog').showModal();
    $('#confirm-delete').onclick = () => {
      const button = $<HTMLButtonElement>('#confirm-delete'); button.disabled = true;
      void (async () => { try {
        if (playlist.is_default) { await api.removeTrack(track.id); player.remove(track.id); }
        else await api.detachTrack(playlist.id, track.id);
        dialog('confirm-dialog').close(); await refresh(); toast(playlist.is_default ? 'Трек удалён из медиатеки' : 'Трек убран из плейлиста');
      } catch (error) { toast(errorMessage(error)); } finally { button.disabled = false; } })();
    };
  };
  dialog('track-dialog').showModal();
}
let polling = false;
setInterval(() => {
  if (!user || !navigator.onLine || document.hidden || polling) return;
  polling = true;
  void (async () => {
    try {
      await uploads.poll();
      await spotify.poll();
      if (selected?.tracks.some((t) => t.status !== 'streamed')) {
        const id = selected.id; const requestVersion = version; const updated = await api.playlist(id);
        if (selected?.id === id && version === requestVersion && JSON.stringify(updated.tracks) !== JSON.stringify(selected.tracks)) { selected = updated; renderCollection(); }
      }
    } catch (error) { if (error instanceof ApiError && error.status === 401) { clearSession(); toast('Сессия завершилась. Войдите снова.'); dialog('auth-dialog').showModal(); } }
    finally { polling = false; }
  })();
}, 5000);
function connection(): void { $('#connection').hidden = navigator.onLine; }
window.addEventListener('online', () => { connection(); if (user) void refresh().catch((error: unknown) => toast(errorMessage(error))); });
window.addEventListener('offline', connection); connection();
const updateSW = registerSW({ onNeedRefresh: () => { $('#update').hidden = false; }, onRegisterError: (error: unknown) => console.error('Service worker registration failed', error) });
$('#update').onclick = () => { if (uploads.busy) toast('Сначала завершите загрузку'); else void updateSW(true); };
void openSession().catch((error: unknown) => { if (!(error instanceof ApiError && error.status === 401)) toast(errorMessage(error)); renderSidebar(); dialog('auth-dialog').showModal(); });
