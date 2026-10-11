import type { Playlist } from './model';
import type { LanguageState } from '../../shared/i18n/state.svelte';

/** Форматирует серверную сумму длительностей, отмечая ещё неизвестные значения. */
export function playlistDuration(
  playlist: Pick<Playlist, 'duration_seconds' | 'duration_complete'>,
  language: LanguageState,
): string {
  const duration = playlist.duration_seconds;
  if (duration == null) return language.t('playlists.durationUnknown');

  const hours = Math.floor(duration / 3600);
  const minutes = Math.floor((duration % 3600) / 60);
  const seconds = duration % 60;
  const formatted =
    hours > 0
      ? language.t('duration.hoursMinutes', { hours, minutes })
      : seconds === 0
        ? language.t('duration.minutes', { minutes })
        : minutes > 0
          ? language.t('duration.minutesSeconds', { minutes, seconds })
          : language.t('duration.seconds', { seconds });

  return playlist.duration_complete
    ? formatted
    : language.t('playlists.durationPartial', { duration: formatted });
}
