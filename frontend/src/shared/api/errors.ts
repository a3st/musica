import { t } from '../i18n';
export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
  ) {
    super(code);
  }
}

export function errorMessage(error: unknown): string {
  if (error instanceof ApiError) {
    const messages: Record<string, string> = {
      unauthorized: t('auth.loginRequired'),
      invalid_credentials: t('auth.credentialsRules'),
      conflict: t('auth.usernameTaken'),
      invalid_track_metadata: t('tracks.metadataRules'),
      file_too_large: t('uploads.tooLarge'),
      track_preparation_in_progress: t('tracks.preparingDeleteBlocked'),
      upload_in_progress: t('tracks.uploadInProgress'),
      not_found: t('errors.notFound'),
      track_not_found: t('tracks.notFound'),
      internal_error: t('errors.requestFailed'),
      web_search_unavailable: t('web.unavailable'),
      hls_not_ready: t('player.notReady'),
    };
    return messages[error.code] ?? t('errors.requestStatus', { status: error.status });
  }
  if (error instanceof Error)
    return error.name === 'TimeoutError'
      ? t('errors.timeout')
      : error.name === 'TypeError'
        ? t('errors.connection')
        : error.message;
  return t('errors.actionFailed');
}
