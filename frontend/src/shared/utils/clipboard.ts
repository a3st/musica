import { t } from '../i18n';
export async function copyText(text: string): Promise<void> {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const input = document.createElement('textarea');
    input.value = text;
    input.style.position = 'fixed';
    input.style.opacity = '0';
    document.body.append(input);
    input.select();
    try {
      if (!document.execCommand('copy')) throw new Error(t('share.copyFailed'));
    } finally {
      input.remove();
    }
  }
}
