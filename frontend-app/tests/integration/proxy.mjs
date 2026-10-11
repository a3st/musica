import assert from 'node:assert/strict';
import { createServer as httpServer } from 'node:http';
import { resolve } from 'node:path';
import { createServer, loadConfigFromFile } from 'vite';

// Exercise the actual Vite proxy configuration without touching user data.
const received = [];
const backend = httpServer((request, response) => {
  received.push({ method: request.method, path: request.url, headers: request.headers });
  request.resume();
  request.on('end', () => { response.writeHead(204); response.end(); });
});
await new Promise((resolve) => backend.listen(0, '127.0.0.1', resolve));
let vite;
try {
  const { config } = await loadConfigFromFile({ command: 'serve', mode: 'development' }, resolve('vite.config.ts'));
  const configured = config.server.proxy['/api'];
  const target = `http://127.0.0.1:${backend.address().port}`;
  // Override only the destination, keeping production options (including string shorthand).
  const proxy = typeof configured === 'string' ? target : { ...configured, target };
  // This test sends only API requests; scanning UI dependencies has no purpose here.
  vite = await createServer({ ...config, configFile: false,
    optimizeDeps: { noDiscovery: true, include: [] }, server: {
    ...config.server, host: '127.0.0.1', port: 0, strictPort: false, proxy: { '/api': proxy },
  } });
  await vite.listen();
  const port = vite.httpServer.address().port;
  for (const host of ['127.0.0.1', 'localhost']) {
    const origin = `http://${host}:${port}`;
    for (const [method, path, type, body] of [
      ['POST', '/api/playlists', 'application/json', JSON.stringify({ title: 'Proxy fixture' })],
      ['POST', '/api/tracks', 'application/json', JSON.stringify({ title: 'Track', artist: 'Artist' })],
      ['PUT', '/api/tracks/00000000-0000-4000-8000-000000000001/file', 'audio/mpeg', 'audio fixture'],
    ]) {
      const response = await fetch(`${origin}${path}`, { method, body, headers: {
        Origin: origin, Cookie: `musica_session=${'a'.repeat(64)}`, 'Content-Type': type,
      } });
      assert.equal(response.status, 204);
      const forwarded = received.at(-1);
      assert.equal(forwarded.method, method);
      assert.equal(forwarded.path, path);
      assert.equal(forwarded.headers.host, `${host}:${port}`, 'Vite must preserve frontend Host for cookie CSRF checks');
      assert.equal(forwarded.headers.origin, origin);
      assert.equal(forwarded.headers.cookie, `musica_session=${'a'.repeat(64)}`);
    }
  }
  console.log('PASS: real Vite proxy preserves Host, Origin and cookie for playlist creation, track creation and file upload.');
} finally {
  if (vite) await vite.close();
  backend.closeAllConnections();
  await new Promise((resolve) => backend.close(resolve));
}
