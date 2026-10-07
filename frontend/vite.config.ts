import { defineConfig } from 'vite';
import { VitePWA } from 'vite-plugin-pwa';

export default defineConfig({
  preview: { proxy: {} },
  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      // Preserve the browser's Host so backend cookie Origin checks remain valid.
      '/api': { target: 'http://127.0.0.1:8080', changeOrigin: false },
    },
  },
  plugins: [
    VitePWA({
      registerType: 'prompt',
      includeAssets: ['icon.svg'],
      manifest: {
        id: '/',
        name: 'Musica',
        short_name: 'Musica',
        description: 'Ваш музыкальный плеер на собственном сервере',
        lang: 'ru',
        start_url: '/',
        scope: '/',
        display: 'standalone',
        background_color: '#171917',
        theme_color: '#171917',
        icons: [
          { src: '/icon-192.png', sizes: '192x192', type: 'image/png' },
          { src: '/icon-512.png', sizes: '512x512', type: 'image/png' },
          { src: '/icon.svg', sizes: 'any', type: 'image/svg+xml' },
        ],
      },
      workbox: {
        globPatterns: ['**/*.{js,css,html,svg,png}'],
        navigateFallbackDenylist: [/^\/api(?:\/|$)/],
      },
    }),
  ],
});
