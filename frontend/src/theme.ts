import { t } from './i18n';
import { icon } from './icons';

export function initTheme(): void {
  let theme = 'dark';
  try { theme = localStorage.getItem('musica:theme') === 'light' ? 'light' : 'dark'; } catch { /* Storage is optional. */ }
  const button = document.querySelector<HTMLButtonElement>('#theme-toggle')!;
  function apply(): void {
    document.documentElement.dataset.theme = theme;
    button.title = theme === 'dark' ? t('Включить светлую тему') : t('Включить тёмную тему');
    button.innerHTML = icon(theme === 'dark' ? 'sun' : 'moon') + button.title;
    button.setAttribute('aria-label', button.title);
    document.querySelector<HTMLMetaElement>('meta[name="theme-color"]')!.content = theme === 'dark' ? '#0b0f1c' : '#f1f5f9';
  }
  apply();
  window.addEventListener('localechange', apply);
  button.onclick = () => {
    theme = theme === 'dark' ? 'light' : 'dark';
    apply();
    try { localStorage.setItem('musica:theme', theme); } catch { /* Theme still works for this session. */ }
  };
}
