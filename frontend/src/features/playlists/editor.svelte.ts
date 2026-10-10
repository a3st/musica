import { playlistsApi } from './api';
import { errorMessage } from '../../shared/api/errors';
import { t } from '../../shared/i18n';
import type { Playlist } from './model';
import { playlistImageUrl } from './image';

export class PlaylistEditorState {
  open = $state(false);
  id = $state<string | null>(null);
  title = $state('');
  description = $state('');
  visibility = $state<Playlist['visibility']>('private');
  image = $state.raw<File | null>(null);
  existingImage = $state<string | null>(null);
  busy = $state(false);
  error = $state('');
  private tags: string[] = [];
  private opening = 0;
  constructor(
    private readonly saved: (id: string) => Promise<void>,
    private readonly notify: (message: string) => void,
  ) {}
  async edit(id?: string): Promise<void> {
    if (this.busy) return;
    const version = ++this.opening;
    const playlist = id ? await playlistsApi.playlist(id) : null;
    if (version !== this.opening) return;
    if (playlist?.is_default) {
      this.notify(t('playlists.defaultProtected'));
      return;
    }
    this.id = playlist?.id ?? null;
    this.tags = playlist?.tags ?? [];
    this.image = null;
    this.error = '';
    this.existingImage = playlist?.image_key ? playlistImageUrl(playlist) : null;
    this.title = playlist?.title ?? '';
    this.description = playlist?.description ?? '';
    this.visibility = playlist?.visibility ?? 'private';
    this.open = true;
  }
  chooseImage(file: File): void {
    if (this.busy) return;
    if (
      !file.size ||
      file.size > 5 * 1024 * 1024 ||
      (file.type
        ? !['image/png', 'image/jpeg', 'image/webp'].includes(file.type)
        : !/\.(png|jpe?g|webp)$/i.test(file.name))
    ) {
      this.error = t('playlists.artworkInvalid');
      return;
    }
    this.error = '';
    this.image = file;
  }
  async save(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    this.error = '';
    const image = this.image;
    const creating = !this.id;
    let metadataSaved = false;
    try {
      if (this.id)
        await playlistsApi.updatePlaylist(
          this.id,
          this.title.trim(),
          this.description.trim(),
          this.visibility,
          this.tags,
        );
      else
        this.id = await playlistsApi.createPlaylist(
          this.title.trim(),
          this.description.trim(),
          this.visibility,
        );
      metadataSaved = true;
      if (image) await playlistsApi.setPlaylistImage(this.id, image);
      await this.saved(this.id);
      this.open = false;
      this.notify(creating ? t('playlists.created') : t('playlists.updated'));
    } catch (error) {
      this.error =
        metadataSaved && image
          ? t('playlists.artworkUploadFailed') + ' ' + errorMessage(error)
          : errorMessage(error);
      if (metadataSaved && this.id) {
        try {
          await this.saved(this.id);
        } catch {
          /* Preserve the original failure. */
        }
      }
    } finally {
      this.busy = false;
    }
  }
  reset(): void {
    this.opening++;
    this.open = false;
    this.image = null;
  }
}
