export type UploadStatus = 'waiting' | 'uploading' | 'preparing' | 'done' | 'error' | 'cancelled';

export interface UploadItem {
  key: number;
  file: File;
  title: string;
  artist: string;
  state: UploadStatus;
  progress: number;
  id?: string;
  uploaded?: boolean;
  error?: string;
  controller?: AbortController;
}
