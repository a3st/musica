import { t } from '../../src/shared/i18n';

// These calls are checked by svelte-check, never executed in the application.
t('uploads.title');
t('tracks.play', { title: 'Midnight City' });
t('playlists.trackCount', { count: 0 });

// @ts-expect-error Unknown translation keys must fail compilation.
t('uploads.unknown');
// @ts-expect-error Interpolated messages require their parameters.
t('tracks.play');
// @ts-expect-error Parameter names are part of the translation contract.
t('tracks.play', { name: 'Midnight City' });
// @ts-expect-error Messages without placeholders do not accept parameters.
t('uploads.title', { count: 1 });
