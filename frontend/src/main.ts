import { mount, unmount } from 'svelte';
import App from './app/App.svelte';
import './app/styles.css';

const target = document.querySelector<HTMLElement>('#app');
if (!target) throw new Error('Application root is missing');
const app = mount(App, { target });

if (import.meta.hot) {
  import.meta.hot.accept();
  import.meta.hot.dispose(() => {
    void unmount(app);
  });
}
