import type { Application } from './state.svelte';
import type { MenuItem } from '../shared/ui/menu.svelte';
import type { PlaylistSummary } from '../features/playlists/model';
import type { Track } from '../features/tracks/model';
import type { SearchTrack } from '../features/web-search/model';
import { playlistsApi } from '../features/playlists/api';
import { tracksApi } from '../features/tracks/api';
import { copyText } from '../shared/utils/clipboard';

export function playlistMenu(app: Application, playlist: PlaylistSummary): MenuItem[] {
  const { t } = app.language;
  return [
    {
      label: t('playlists.open'),
      icon: 'library',
      group: 'navigation',
      action: () => app.run(app.selectPlaylist(playlist.id)),
    },
    {
      label: t('playlists.edit'),
      icon: 'edit',
      group: 'settings',
      id: 'edit-playlist',
      disabled: playlist.is_default || playlist.role === 'viewer',
      hint: playlist.is_default ? t('playlists.defaultProtected') : undefined,
      action: () => {
        app.libraryOpen = false;
        app.run(app.editor.edit(playlist.id));
      },
    },
    {
      label: t('share.copyLink'),
      icon: 'link',
      group: 'sharing',
      id: 'share-playlist',
      disabled:
        playlist.is_default ||
        playlist.visibility === 'private' ||
        (playlist.visibility === 'unlisted' && playlist.role !== 'owner'),
      hint: playlist.visibility === 'private' ? t('share.chooseVisibility') : undefined,
      action: () => app.run(copyShareLink(app, playlist)),
    },
    {
      label: playlist.is_default ? t('playlists.defaultDeleteProtected') : t('playlists.delete'),
      icon: 'trash',
      group: 'danger',
      id: 'delete-playlist',
      danger: true,
      disabled: playlist.is_default || playlist.role !== 'owner',
      action: () => {
        app.libraryOpen = false;
        app.confirmation = {
          title: t('playlists.deleteTitle'),
          description: t('playlists.deleteDescription', { title: playlist.title }),
          remove: async () => {
            await playlistsApi.removePlaylist(playlist.id);
            await app.refresh();
            app.notify(t('playlists.deleted'));
          },
        };
      },
    },
  ];
}
async function copyShareLink(app: Application, playlist: PlaylistSummary): Promise<void> {
  const url = new URL('/', location.origin);
  if (playlist.visibility === 'public') url.searchParams.set('playlist', playlist.id);
  else {
    let token = app.library.shareLinks.get(playlist.id);
    if (!token) {
      token = await playlistsApi.createShareLink(playlist.id);
      app.library.shareLinks.set(playlist.id, token);
    }
    url.hash = 'share=' + token;
  }
  await copyText(url.href);
  app.notify(app.language.t('share.copied'));
}
export function webTrackMenu(app: Application, track: SearchTrack): MenuItem[] {
  const { t } = app.language;
  const targets = app.library.items.filter(
    (playlist) => playlist.role !== 'viewer' && !playlist.is_default,
  );
  return [
    {
      label: t('web.addToUploads'),
      icon: 'plus',
      group: 'organize',
      disabled: !app.importsEnabled,
      action: () => app.run(app.addWebTrack(track)),
    },
    {
      label: t('tracks.addToPlaylist'),
      icon: 'plus',
      group: 'organize',
      disabled: !app.importsEnabled || !targets.length,
      children: targets.map((playlist) => ({
        label: playlist.title,
        icon: 'library',
        action: () => app.run(app.addWebTrack(track, playlist.id)),
      })),
    },
    {
      label: t('web.openSource'),
      icon: 'link',
      group: 'sharing',
      disabled: !track.source_url,
      action: () => {
        if (track.source_url) window.open(track.source_url, '_blank', 'noopener,noreferrer');
      },
    },
  ];
}

export function serviceTrackMenu(app: Application, track: Track): MenuItem[] {
  const { t } = app.language;
  const targets = app.library.items.filter(
    (playlist) => playlist.role !== 'viewer' && !playlist.is_default,
  );
  return [
    {
      label: t('web.addToUploads'),
      icon: 'plus',
      group: 'organize',
      disabled: !!app.search.serviceAdditions[track.id],
      action: () => app.run(app.addServiceTrack(track)),
    },
    {
      label: t('tracks.addToPlaylist'),
      icon: 'plus',
      group: 'organize',
      disabled: !targets.length,
      children: targets.map((playlist) => ({
        label: playlist.title,
        icon: 'library',
        action: () => app.run(app.addServiceTrack(track, playlist.id)),
      })),
    },
  ];
}

export function trackMenu(app: Application, track: Track): MenuItem[] {
  const playlist = app.library.selected;
  if (!playlist) return [];
  const { t } = app.language;
  const deletesTrack = playlist.is_default && track.owner_id === app.auth.user?.id;
  const targets = app.library.items.filter(
    (item) => item.role !== 'viewer' && !item.is_default && item.id !== playlist.id,
  );
  return [
    {
      label: t('player.play'),
      icon: 'play',
      group: 'playback',
      disabled: track.status === 'pending',
      action: () => app.play(track),
    },
    {
      label: t('queue.playNext'),
      icon: 'next',
      group: 'queue',
      disabled: track.status === 'pending',
      action: () => {
        if (!app.player.value.current) app.player.cover = playlist;
        app.player.engine.enqueue(track, true);
      },
    },
    {
      label: t('queue.add'),
      icon: 'queue',
      group: 'queue',
      disabled: track.status === 'pending',
      action: () => {
        if (!app.player.value.current) app.player.cover = playlist;
        app.player.engine.enqueue(track);
      },
    },
    {
      label: t('tracks.addToPlaylist'),
      icon: 'plus',
      group: 'organize',
      id: 'attach-track',
      disabled:
        !app.auth.user ||
        (track.owner_kind !== 'system' && track.owner_id !== app.auth.user.id) ||
        !targets.length,
      children: targets.map((target) => ({
        label: target.title,
        icon: 'library',
        group: 'playlists',
        action: () =>
          app.run(
            (async () => {
              await playlistsApi.attachTrack(target.id, track.id);
              await app.refresh();
              app.notify(t('tracks.addedToPlaylist'));
            })(),
          ),
      })),
    },
    {
      label: deletesTrack ? t('tracks.deleteFromLibrary') : t('tracks.removeFromPlaylist'),
      icon: 'trash',
      group: 'danger',
      id: 'remove-track',
      danger: true,
      disabled: !app.library.writable(playlist.id),
      action: () => {
        app.confirmation = {
          title: deletesTrack ? t('tracks.deleteTitle') : t('tracks.removeTitle'),
          description:
            playlist.is_default && track.owner_kind === 'system'
              ? t('tracks.removeSharedDescription', { title: track.title })
              : deletesTrack
                ? t('tracks.deleteDescription', { title: track.title })
                : t('tracks.removeDescription', { title: track.title }),
          remove: async () => {
            if (playlist.is_default) {
              await tracksApi.removeTrack(track.id);
              app.player.engine.remove(track.id);
            } else await playlistsApi.detachTrack(playlist.id, track.id);
            await app.refresh();
            app.notify(
              deletesTrack ? t('tracks.deletedFromLibrary') : t('tracks.removedFromPlaylist'),
            );
          },
        };
      },
    },
  ];
}
