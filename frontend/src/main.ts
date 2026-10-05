import { registerSW } from 'virtual:pwa-register';
import './style.css';

const status = document.querySelector<HTMLParagraphElement>('#api-status')!;
const retry = document.querySelector<HTMLButtonElement>('#retry')!;
const update = document.querySelector<HTMLButtonElement>('#update')!;
const pwaStatus = document.querySelector<HTMLParagraphElement>('#pwa-status')!;

async function checkHealth(): Promise<void> {
  retry.disabled = true;
  status.textContent = 'Проверяем подключение к серверу…';
  try {
    const response = await fetch('/api/health', {
      cache: 'no-store',
      signal: AbortSignal.timeout(5000),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const health: unknown = await response.json();
    if (
      typeof health !== 'object' || health === null ||
      !('status' in health) || health.status !== 'ok' ||
      !('service' in health) || health.service !== 'musica'
    ) throw new Error('Unexpected health response');
    status.textContent = 'Сервер подключён';
  } catch {
    status.textContent = 'Сервер недоступен. Проверьте подключение и запуск backend.';
  } finally {
    retry.disabled = false;
  }
}

const updateSW = registerSW({
  onNeedRefresh() { update.hidden = false; },
  onOfflineReady() {
    pwaStatus.textContent = 'Приложение готово к открытию без сети. Для музыки потребуется сервер.';
  },
  onRegisterError(error: unknown) {
    console.error('Service worker registration failed', error);
    pwaStatus.textContent = 'Не удалось включить офлайн-режим.';
  },
});

update.addEventListener('click', () => { void updateSW(true); });
retry.addEventListener('click', () => { void checkHealth(); });
void checkHealth();
