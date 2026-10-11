import { t } from '../../shared/i18n';
import { ApiError } from '../../shared/api/errors';
import { record, text } from '../../shared/api/validation';

/** Загружает файл через XHR с прогрессом; снимает слушатель отмены при любом завершении. */
export function uploadFile(
  id: string,
  file: File,
  progress: (percent: number) => void,
  signal: AbortSignal,
): Promise<void> {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    const abort = () => xhr.abort();
    xhr.open('PUT', `/api/tracks/${id}/file`);
    xhr.withCredentials = true;
    xhr.timeout = 120000;
    const mime = file.name.toLowerCase().endsWith('.mp3')
      ? 'audio/mpeg'
      : file.type || 'application/octet-stream';
    xhr.setRequestHeader('Content-Type', mime);
    xhr.upload.onprogress = (event) => {
      if (event.lengthComputable) progress(Math.round((event.loaded / event.total) * 100));
    };
    const finish = () => signal.removeEventListener('abort', abort);
    xhr.onload = () => {
      finish();
      if (xhr.status >= 200 && xhr.status < 300) resolve();
      else {
        let code = 'upload_failed';

        try {
          code = text(record(JSON.parse(xhr.responseText) as unknown).error);
        } catch {
          /* Keep generic message. */
        }
        reject(new ApiError(xhr.status, code));
      }
    };
    xhr.onerror = () => {
      finish();
      reject(new Error(t('uploads.connectionFailed')));
    };
    xhr.ontimeout = () => {
      finish();
      reject(new Error(t('uploads.timeout')));
    };
    xhr.onabort = () => {
      finish();
      reject(new DOMException(t('uploads.cancelled'), 'AbortError'));
    };
    signal.addEventListener('abort', abort, { once: true });
    if (signal.aborted) {
      finish();
      reject(new DOMException(t('uploads.cancelled'), 'AbortError'));

      return;
    }
    xhr.send(file);
  });
}
