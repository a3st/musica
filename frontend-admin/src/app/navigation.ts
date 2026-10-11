export type Page = 'profile' | 'users' | 'storage';

/** Читает раздел из URL; неизвестный раздел открывает профиль. */
export function readPage(): Page {
  const page = new URL(window.location.href).searchParams.get('page');
  return page === 'users' || page === 'storage' ? page : 'profile';
}

/** Сохраняет раздел без перезагрузки, поддерживая историю браузера. */
export function writePage(page: Page): void {
  const url = new URL(window.location.href);
  url.searchParams.set('page', page);
  history.pushState(null, '', url);
}
