import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

export default defineConfig({
  base: '/profile/',
  plugins: [svelte()],
  server: {
    port: 5174,
    strictPort: true,
    proxy: {
      // Сохраняем Host для проверки Origin в запросах с cookie-сессией.
      '/api': { target: 'http://127.0.0.1:8080', changeOrigin: false },
    },
  },
  preview: {
    port: 4174,
    strictPort: true,
    proxy: {},
  },
});
