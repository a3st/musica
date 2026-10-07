"""API and migration checks in a disposable PostgreSQL; no user DB is touched.

Run from the repository root: python backend/tests/api_integration.py
Requires Python 3, Docker Compose, Zig 0.16 and the postgres:17-bookworm image.
The S3 endpoint is an in-process mock; SigV4 has separate Zig tests.
"""
import json
import argparse
import hashlib
import hmac
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[2]
BACKEND = ROOT / "backend"


def run_checks(optimize="Debug", backend_image=None):
    project = "musica-api-test-" + uuid.uuid4().hex[:8]
    env = os.environ.copy()
    env.update(PGDATABASE="musica", PGUSER="musica", PGPASSWORD="test-db-password",
               PGPORT="0", S3_ACCESS_KEY_ID="test-access", S3_SECRET_ACCESS_KEY="test-secret",
               S3_REGION="us-east-1", S3_BUCKET="uploads")
    compose = ["docker", "compose", "--env-file", str(ROOT / ".env.docker.example"), "-p", project]

    def docker(*args):
        return subprocess.check_output(compose + list(args), cwd=ROOT, env=env, text=True).strip()

    def sql(query):
        return docker("exec", "-T", "postgres", "psql", "-U", "musica", "-d", "musica", "-v", "ON_ERROR_STOP=1", "-At", "-c", query)

    objects = {}
    blocked_path = None
    upload_arrived = threading.Event()
    release_upload = threading.Event()
    reject_upload = False
    reject_read = False
    blocked_get_path = None
    download_arrived = threading.Event()
    release_download = threading.Event()

    def validate_signature(handler, body):
        payload_hash = hashlib.sha256(body).hexdigest()
        assert handler.headers['x-amz-content-sha256'] == payload_hash
        timestamp = handler.headers['x-amz-date']
        scope = timestamp[:8] + '/us-east-1/s3/aws4_request'
        signed_headers = 'content-type;host;x-amz-content-sha256;x-amz-date'
        canonical = (handler.command + '\n' + handler.path + '\n\ncontent-type:' + handler.headers['Content-Type']
                     + '\nhost:' + handler.headers['Host'] + '\nx-amz-content-sha256:' + payload_hash
                     + '\nx-amz-date:' + timestamp + '\n\n' + signed_headers + '\n' + payload_hash)
        to_sign = 'AWS4-HMAC-SHA256\n' + timestamp + '\n' + scope + '\n' + hashlib.sha256(canonical.encode()).hexdigest()
        key = b'AWS4test-secret'
        for value in (timestamp[:8], 'us-east-1', 's3', 'aws4_request'):
            key = hmac.new(key, value.encode(), hashlib.sha256).digest()
        signature = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
        assert handler.headers['Authorization'] == ('AWS4-HMAC-SHA256 Credential=test-access/' + scope
                                                    + ', SignedHeaders=' + signed_headers + ', Signature=' + signature)

    class S3Mock(BaseHTTPRequestHandler):
        def do_PUT(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            validate_signature(self, body)
            if reject_upload:
                self.send_response(503)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if self.path == blocked_path:
                upload_arrived.set()
                assert release_upload.wait(10), "test did not release the S3 upload"
            objects[self.path] = body
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self):
            validate_signature(self, b'')
            if self.path == blocked_get_path and not download_arrived.is_set():
                download_arrived.set()
                assert release_download.wait(40), 'test did not release original download'
            body = objects.get(self.path)
            self.send_response(503 if reject_read else 404 if body is None else 200)
            self.send_header('Content-Length', str(len(body) if body is not None and not reject_read else 0))
            self.end_headers()
            if body is not None and not reject_read:
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                    pass  # A lease-losing worker cancels its download.

        def log_message(self, *_):
            pass

    storage = ThreadingHTTPServer(("0.0.0.0" if backend_image else "127.0.0.1", 0), S3Mock)
    threading.Thread(target=storage.serve_forever, daemon=True).start()
    server = None
    log = None
    containers = []

    def start_node(worker):
        name = project + '-node-' + str(len(containers))
        node_env = dict(HTTP_HOST='0.0.0.0', HTTP_PORT='8080', PGHOST='postgres', PGPORT='5432',
                        PGDATABASE='musica', PGUSER='musica', PGPASSWORD='test-db-password',
                        S3_ENDPOINT=f'http://host.docker.internal:{storage.server_port}',
                        S3_REGION='us-east-1', S3_BUCKET='uploads', S3_ACCESS_KEY_ID='test-access',
                        S3_SECRET_ACCESS_KEY='test-secret', HLS_WORKER_ENABLED=str(worker).lower())
        command = ['docker', 'run', '-d', '--name', name, '--network', project + '_default',
                   '-p', '127.0.0.1::8080', '--add-host', 'host.docker.internal:host-gateway']
        for key, value in node_env.items():
            command += ['-e', key + '=' + value]
        command += [backend_image]
        subprocess.check_output(command, text=True)
        containers.append(name)
        mapped = subprocess.check_output(['docker', 'port', name, '8080'], text=True).strip().rsplit(':', 1)[1]
        return f'http://127.0.0.1:{mapped}'
    try:
        docker("up", "-d", "--wait", "postgres")
        port = docker("port", "postgres", "5432").rsplit(":", 1)[1]
        for name in ("001_create_albums.sql", "002_create_tracks.sql"):
            docker("exec", "-T", "postgres", "psql", "-U", "musica", "-d", "musica", "-v", "ON_ERROR_STOP=1", "-f", "/migrations/" + name)
        legacy_playlist = "11111111-1111-4111-8111-111111111111"
        legacy_track = "22222222-2222-4222-8222-222222222222"
        sql(f"INSERT INTO albums (id,title,artist) VALUES ('{legacy_playlist}','Legacy','Artist'); INSERT INTO tracks (id,album_id,title,artist) VALUES ('{legacy_track}','{legacy_playlist}','Legacy track','Artist');")
        for name in ("003_track_albums.sql", "004_users_and_albums.sql"):
            docker("exec", "-T", "postgres", "psql", "-U", "musica", "-d", "musica", "-v", "ON_ERROR_STOP=1", "-f", "/migrations/" + name)
        ready_track = "33333333-3333-4333-8333-333333333333"
        sql(f"INSERT INTO tracks (id,title,artist,status,storage_bucket,object_key,content_type,size_bytes,uploaded_at) VALUES ('{ready_track}','Ready legacy','Artist','ready','old-bucket','old/key','audio/mpeg',5,now())")
        docker("exec", "-T", "postgres", "psql", "-U", "musica", "-d", "musica", "-v", "ON_ERROR_STOP=1",
               "-c", "SET musica.pending_bucket = 'legacy-uploads'", "-f", "/migrations/005_pending_track_storage.sql")
        assert sql(f"SELECT storage_bucket || '/' || object_key FROM tracks WHERE id='{legacy_track}'") == f"legacy-uploads/tracks/{legacy_track}"
        assert sql(f"SELECT storage_bucket || '/' || object_key FROM tracks WHERE id='{ready_track}'") == "old-bucket/old/key"
        assert sql(f"SELECT count(*) FROM track_albums WHERE track_id='{legacy_track}' AND album_id='{legacy_playlist}'") == "1"
        assert sql("SELECT count(*) FROM information_schema.columns WHERE table_name='tracks' AND column_name='album_id'") == "0"
        sql(f"UPDATE albums SET image_key='albums/{legacy_playlist}/old-cover' WHERE id='{legacy_playlist}'")
        docker("exec", "-T", "postgres", "psql", "-U", "musica", "-d", "musica", "-v", "ON_ERROR_STOP=1", "-f", "/migrations/006_albums_to_playlists.sql")
        assert sql(f"SELECT count(*) FROM track_playlists WHERE track_id='{legacy_track}' AND playlist_id='{legacy_playlist}'") == "1"
        assert sql(f"SELECT image_key FROM playlists WHERE id='{legacy_playlist}'") == f"albums/{legacy_playlist}/old-cover"
        assert sql("SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('albums','track_albums','album_members')") == "0"
        docker("exec", "-T", "postgres", "psql", "-U", "musica", "-d", "musica", "-v", "ON_ERROR_STOP=1", "-f", "/migrations/007_remove_playlist_artist.sql")
        assert sql(f"SELECT title FROM playlists WHERE id='{legacy_playlist}'") == "Legacy"
        assert sql(f"SELECT artist FROM tracks WHERE id='{legacy_track}'") == "Artist"
        before_status_migration = sql("SELECT row_to_json(t)::text FROM tracks t ORDER BY id")
        docker("exec", "-T", "postgres", "psql", "-U", "musica", "-d", "musica", "-v", "ON_ERROR_STOP=1", "-f", "/migrations/008_track_status_enum.sql")
        assert sql("SELECT row_to_json(t)::text FROM tracks t ORDER BY id") == before_status_migration
        invalid_status = subprocess.run(
            compose + ["exec", "-T", "postgres", "psql", "-U", "musica", "-d", "musica", "-v", "ON_ERROR_STOP=1", "-c",
                       f"UPDATE tracks SET status='unknown' WHERE id='{legacy_track}'"],
            cwd=ROOT, env=env, text=True, capture_output=True)
        assert invalid_status.returncode != 0 and 'invalid input value for enum track_status' in invalid_status.stderr
        assert sql(f"SELECT status FROM tracks WHERE id='{legacy_track}'") == "pending"
        docker("exec", "-T", "postgres", "psql", "-U", "musica", "-d", "musica", "-v", "ON_ERROR_STOP=1", "-f", "/migrations/009_track_hls.sql")
        assert [json.loads(line) for line in sql("SELECT row_to_json(t)::jsonb - 'hls_bucket' - 'hls_prefix' - 'hls_segment_count' FROM tracks t ORDER BY id").splitlines()] == [
            json.loads(line) for line in before_status_migration.splitlines()]
        if not backend_image:
            subprocess.run(["zig", "build", "-Doptimize=" + optimize], cwd=BACKEND, check=True)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            http_port = listener.getsockname()[1]
        env.update(HTTP_HOST="127.0.0.1", HTTP_PORT=str(http_port), PGHOST="127.0.0.1", PGPORT=port,
                   S3_ENDPOINT=f"http://127.0.0.1:{storage.server_port}", HLS_WORKER_ENABLED='false')
        executable = BACKEND / "zig-out" / "bin" / ("musica-backend.exe" if os.name == "nt" else "musica-backend")
        if backend_image:
            base = start_node(False)
        else:
            log = (BACKEND / ".zig-cache" / "api-integration.log").open("w", encoding="utf-8")
            server = subprocess.Popen([str(executable)], cwd=BACKEND, env=env, stdout=log, stderr=log)
            base = f"http://127.0.0.1:{http_port}"

        def request(method, path, body=None, token=None, expected=200, mime="application/json", raw=False, node=None):
            headers = {"Content-Type": mime}
            if token:
                headers["Authorization"] = "Bearer " + token
            data = body if isinstance(body, bytes) else json.dumps(body).encode() if body is not None else None
            req = urllib.request.Request((node or base) + path, data=data, method=method, headers=headers)
            try:
                response = urllib.request.urlopen(req, timeout=20)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                payload = response.read()
                assert response.status == expected, (method, path, response.status, payload)
                if path != "/api/health":
                    assert response.headers.get("Cache-Control") == "no-store"
                if raw and expected == 200:
                    assert response.headers.get('Content-Type') == ('application/vnd.apple.mpegurl' if 'index.m3u8' in path else 'video/mp2t')
                return payload if raw else json.loads(payload) if payload else None

        for attempt in range(100):
            if server and server.poll() is not None:
                raise RuntimeError("backend exited; see backend/.zig-cache/api-integration.log")
            try:
                request("GET", "/api/health")
                break
            except OSError:
                time.sleep(0.1)
        else:
            raise RuntimeError("backend did not start")

        password = "integration-password-123"
        alice = request("POST", "/api/auth/register", {"username": "alice", "password": password}, expected=201)
        bob = request("POST", "/api/auth/register", {"username": "bob", "password": password}, expected=201)
        a, b = alice["token"], bob["token"]
        default = request("GET", "/api/users/me", token=a)["default_playlist_id"]
        sql("ALTER TABLE playlists RENAME TO temporarily_unavailable_playlists")
        try:
            failure = request("GET", "/api/users/me", token=a, expected=503 if optimize == "Debug" else 500)
            assert failure == {"error": "database_unavailable" if optimize == "Debug" else "internal_error"}
        finally:
            sql("ALTER TABLE temporarily_unavailable_playlists RENAME TO playlists")
        assert sql("SELECT count(*) FROM playlists WHERE is_default") == "2"
        assert sql("SELECT count(*) FROM sessions WHERE length(token_hash)=64") == "2"
        assert sql(f"SELECT count(*) FROM sessions WHERE token_hash='{a}'") == "0"
        request("POST", "/api/auth/register", {"username": "alice", "password": password}, expected=409)
        assert sql("SELECT count(*) FROM playlists WHERE is_default") == "2"
        request("POST", "/api/auth/login", {"username": "alice", "password": "incorrect-password"}, expected=401)
        request("POST", "/api/auth/login", {"username": "missing", "password": password}, expected=401)
        login = request("POST", "/api/auth/login", {"username": "alice", "password": password})
        request("POST", "/api/auth/logout", token=login["token"], expected=204)
        request("GET", "/api/users/me", token=login["token"], expected=401)
        sql(f"UPDATE sessions SET expires_at=now()-interval '1 second' WHERE user_id='{bob['user_id']}'")
        request("GET", "/api/users/me", token=b, expected=401)
        b = request("POST", "/api/auth/login", {"username": "bob", "password": password})["token"]
        request("GET", f"/api/playlists/{legacy_playlist}", token=a, expected=404)
        request("GET", f"/api/playlists/{default}", expected=404)
        request("GET", f"/api/playlists/{default}", token=b, expected=404)
        created = request("POST", "/api/tracks", {"title": "Track", "artist": "Artist"}, token=a, expected=201)
        assert created["status"] == "pending"
        track = created["id"]
        assert sql(f"SELECT storage_bucket || '/' || object_key FROM tracks WHERE id='{track}' AND status='pending' AND content_type IS NULL AND size_bytes IS NULL AND uploaded_at IS NULL") == f"uploads/tracks/{track}/source"
        empty_track = request("POST", "/api/tracks", {"playlist_ids": [], "title": "Empty list", "artist": "Artist"}, token=a, expected=201)["id"]
        assert {t["id"] for t in request("GET", f"/api/playlists/{default}", token=a)["tracks"]} == {track, empty_track}
        request("PUT", f"/api/tracks/{track}/file", b"audio", token=b, expected=404, mime="audio/mpeg")
        assert not objects
        blocked_path = f"/uploads/tracks/{track}/source"
        with ThreadPoolExecutor(max_workers=1) as executor:
            uploading = executor.submit(request, "PUT", f"/api/tracks/{track}/file", b"audio", token=a, mime="audio/mpeg")
            try:
                assert upload_arrived.wait(5), "first upload did not reach S3"
                busy = request("PUT", f"/api/tracks/{track}/file", b"other audio", token=a, expected=409, mime="audio/mpeg")
                assert busy == {"error": "upload_in_progress"}
            finally:
                release_upload.set()
            assert uploading.result(timeout=10)["status"] == "ready"
        blocked_path = None
        assert objects[f"/uploads/tracks/{track}/source"] == b"audio"
        request("PUT", f"/api/tracks/{track}/file", b"audio", token=a, expected=409, mime="audio/mpeg")
        preserved = request("POST", "/api/tracks", {"title": "Historical location", "artist": "Artist"}, token=a, expected=201)["id"]
        # Simulate a track created under an older bucket/key configuration.
        sql(f"UPDATE tracks SET storage_bucket='historical-uploads', object_key='tracks/stored-key' WHERE id='{preserved}'")
        reject_upload = True
        failure = request("PUT", f"/api/tracks/{preserved}/file", b"audio", token=a, expected=502 if optimize == "Debug" else 500, mime="audio/mpeg")
        assert failure == {"error": "storage_unavailable" if optimize == "Debug" else "internal_error"}
        assert sql(f"SELECT storage_bucket || '/' || object_key FROM tracks WHERE id='{preserved}' AND status='pending' AND content_type IS NULL AND size_bytes IS NULL AND uploaded_at IS NULL") == "historical-uploads/tracks/stored-key"
        reject_upload = False
        uploaded = request("PUT", f"/api/tracks/{preserved.upper()}/file", b"audio", token=a, mime="audio/mpeg")
        assert uploaded["bucket"] == "historical-uploads" and uploaded["object_key"] == "tracks/stored-key"
        assert objects["/historical-uploads/tracks/stored-key"] == b"audio"
        assert sql(f"SELECT storage_bucket || '/' || object_key FROM tracks WHERE id='{preserved}' AND status='ready'") == "historical-uploads/tracks/stored-key"
        playlist = request("POST", "/api/playlists", {"title": "Playlist"}, token=a, expected=201)["id"]
        path = f"/api/playlists/{playlist}"
        request("GET", path, expected=404)
        request("GET", path, token=b, expected=404)
        member = path + "/members/" + bob["user_id"]
        request("PUT", member, {"role": "viewer"}, token=a, expected=204)
        request("GET", path, token=b)
        request("PUT", path, {"title": "Denied"}, token=b, expected=404)
        request("PUT", path + "/tracks/" + track, token=b, expected=404)
        request("PUT", path + "/image", b"\x89PNG\r\n\x1a\nfixture", token=b, expected=404, mime="image/png")
        request("PUT", member, {"role": "editor"}, token=a, expected=204)
        request("PUT", path, {"title": "Renamed", "description": "Description", "tags": ["rock", "live"]}, token=b, expected=204)
        metadata = request("GET", path, token=a)
        assert "artist" not in metadata
        assert metadata["title"] == "Renamed" and metadata["tags"] == ["rock", "live"]
        request("PUT", member, {"role": "viewer"}, token=b, expected=404)
        request("PUT", path + "/tracks/" + track, token=b, expected=404)
        request("PUT", path + "/tracks/" + track, token=a, expected=204)
        request("PUT", path + "/tracks/" + track, token=a, expected=204)
        assert len(request("GET", path, token=b)["tracks"]) == 1
        request("DELETE", f"/api/playlists/{default}/tracks/{track}", token=a, expected=400)
        request("PUT", f"/api/playlists/{default}", {"title": "Uploads", "visibility": "public"}, token=a, expected=400)
        count = sql("SELECT count(*) FROM tracks")
        request("POST", "/api/tracks", {"playlist_ids": [playlist, str(uuid.uuid4())], "title": "Rollback", "artist": "Artist"}, token=a, expected=404)
        assert sql("SELECT count(*) FROM tracks") == count
        combined = request("POST", "/api/tracks", {"playlist_ids": [playlist], "title": "Both playlists", "artist": "Artist"}, token=a, expected=201)["id"]
        assert sql(f"SELECT count(*) FROM track_playlists WHERE track_id='{combined}'") == "2"
        cover = b"\x89PNG\r\n\x1a\nfixture"
        image = request("PUT", path + "/image", cover, token=b, mime="image/png")
        assert objects["/uploads/" + image["image_key"]] == cover
        assert request("GET", path, token=a)["image_key"] == image["image_key"]
        request("PUT", path + "/image", b"html", token=a, expected=400, mime="image/png")
        request("PUT", path, {"title": "Public", "visibility": "public"}, token=a, expected=204)
        request("GET", path)
        request("PUT", path, {"title": "Unlisted", "visibility": "unlisted"}, token=a, expected=204)
        request("GET", path, expected=404)
        link = request("POST", path + "/share-link", token=a)["path"]
        request("GET", link)
        rotated = request("POST", path + "/share-link", token=a)["path"]
        request("GET", link, expected=404)
        request("GET", rotated)
        request("DELETE", path + "/share-link", token=a, expected=204)
        request("GET", rotated, expected=404)
        request("DELETE", member, token=a, expected=204)
        request("GET", path, token=b, expected=404)
        pending_hls = f'/api/tracks/{empty_track}/hls'
        assert request('POST', pending_hls, token=a, expected=409) == {'error': 'track_not_uploaded'}
        request('GET', pending_hls + '/index.m3u8', token=a, expected=409)
        assert request('GET', pending_hls + '/status', token=a) == {'status': 'pending', 'preparation': None}
        request('POST', f'/api/tracks/{track}/hls', token=b, expected=404)

        if backend_image:
            mp3 = subprocess.check_output(['docker', 'run', '--rm', '--entrypoint', 'ffmpeg', backend_image,
                                          '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=13',
                                          '-c:a', 'libmp3lame', '-f', 'mp3', 'pipe:1'])
            playable = request('POST', '/api/tracks', {'title': 'HLS fixture', 'artist': 'Test'}, token=a, expected=201)['id']
            request('PUT', f'/api/tracks/{playable}/file', mp3, token=a, mime='audio/mpeg')
            hls = f'/api/tracks/{playable}/hls'
            assert request('POST', hls, token=a, expected=202) == {'status': 'ready', 'preparation': 'queued'}
            assert request('POST', hls, token=a, expected=202)['preparation'] == 'queued'
            assert sql(f"SELECT count(*) FROM track_hls_jobs WHERE track_id='{playable}'") == '1'
            blocked_get_path = f'/uploads/tracks/{playable}/source'
            first_node = start_node(True)
            assert download_arrived.wait(15), 'worker did not download original'
            first_attempt = sql(f"SELECT attempt_id FROM track_hls_jobs WHERE track_id='{playable}'")
            assert request('POST', hls, token=a, expected=202)['preparation'] == 'processing'
            assert sql(f"SELECT attempt_id FROM track_hls_jobs WHERE track_id='{playable}'") == first_attempt
            # Simulate a node that stopped renewing its lease. A different node must claim it.
            sql(f"UPDATE track_hls_jobs SET lease_until=now()-interval '1 second' WHERE track_id='{playable}'")
            second_node = start_node(True)

            def wait_preparation(track_path, expected):
                for _ in range(200):
                    state = request('GET', track_path + '/status', token=a)
                    if state['preparation'] == expected:
                        return state
                    time.sleep(0.1)
                raise AssertionError(('HLS preparation did not finish', state))

            assert wait_preparation(hls, 'ready')['status'] == 'streamed'
            current_attempt = sql(f"SELECT attempt_id FROM track_hls_jobs WHERE track_id='{playable}'")
            assert current_attempt != first_attempt
            prefix = sql(f"SELECT hls_prefix FROM tracks WHERE id='{playable}'")
            assert prefix.endswith(current_attempt)
            release_download.set()
            # Playback uses the HTTP node with its worker disabled, independent of preparation.
            manifest = request('GET', hls + '/index.m3u8', token=a, raw=True).decode()
            assert '#EXT-X-PLAYLIST-TYPE:VOD' in manifest and '#EXT-X-ENDLIST' in manifest
            segment_names = [line for line in manifest.splitlines() if line and not line.startswith('#')]
            assert len(segment_names) == 3, manifest
            segment_data = request('GET', hls + '/' + segment_names[0], token=a, raw=True, node=second_node)
            assert segment_data == objects[f'/uploads/{prefix}/segment-000000.ts']
            probe = subprocess.check_output(['docker', 'run', '--rm', '-i', '--entrypoint', 'ffprobe', backend_image,
                                             '-v', 'error', '-show_entries', 'stream=codec_name,codec_type',
                                             '-of', 'json', '-i', 'pipe:0'], input=segment_data)
            assert any(s['codec_name'] == 'aac' and s['codec_type'] == 'audio' for s in json.loads(probe)['streams'])
            assert request('POST', hls, token=a) == {'status': 'streamed', 'preparation': 'ready'}
            request('PUT', f'/api/tracks/{playable}/file', mp3, token=a, mime='audio/mpeg', expected=409)
            request('GET', hls + '/segments/segment-000003.ts', token=a, expected=404)
            request('GET', hls + '/segments/segment-00000a.ts', token=a, expected=404)
            request('GET', hls + '/index.m3u8', token=b, expected=404)
            request('GET', hls + '/' + segment_names[0], expected=404)
            reject_read = True
            try:
                failure = request('GET', hls + '/' + segment_names[0], token=a, expected=502 if optimize == 'Debug' else 500)
                assert failure == {'error': 'storage_unavailable' if optimize == 'Debug' else 'internal_error'}
            finally:
                reject_read = False
            request('PUT', path + '/tracks/' + playable, token=a, expected=204)
            request('PUT', member, {'role': 'viewer'}, token=a, expected=204)
            request('GET', hls + '/' + segment_names[0], token=b, raw=True)
            request('POST', hls, token=b, expected=404)
            request('DELETE', member, token=a, expected=204)
            request('GET', hls + '/' + segment_names[0], token=b, expected=404)
            request('PUT', path, {'title': 'Public', 'visibility': 'public'}, token=a, expected=204)
            request('GET', hls + '/index.m3u8', raw=True)
            request('PUT', path, {'title': 'Unlisted', 'visibility': 'unlisted'}, token=a, expected=204)
            shared = request('POST', path + '/share-link', token=a)['path'].rsplit('/', 1)[1]
            shared_manifest = request('GET', hls + '/index.m3u8?share_token=' + shared, raw=True).decode()
            shared_segment = next(line for line in shared_manifest.splitlines() if line.startswith('segments/'))
            assert shared_segment.endswith('?share_token=' + shared)
            request('GET', hls + '/' + shared_segment, raw=True)
            request('DELETE', path + '/share-link', token=a, expected=204)
            request('GET', hls + '/' + shared_segment, expected=404)
            # Invalid media never publishes streamed, and a retry reuses the job row.
            invalid_hls = f'/api/tracks/{track}/hls'
            request('POST', invalid_hls, token=a, expected=202)
            assert wait_preparation(invalid_hls, 'failed')['status'] == 'ready'
            request('GET', invalid_hls + '/index.m3u8', token=a, expected=409)
            request('POST', invalid_hls, token=a, expected=202)
            assert wait_preparation(invalid_hls, 'failed')['status'] == 'ready'
            assert sql(f"SELECT count(*) FROM track_hls_jobs WHERE track_id='{track}'") == '1'
            for _ in range(100):
                first_logs = subprocess.check_output(['docker', 'logs', containers[1]], stderr=subprocess.STDOUT, text=True)
                if 'LeaseLost' in first_logs:
                    break
                time.sleep(0.1)
            else:
                raise AssertionError('old worker did not reject its expired/replaced lease')
            assert sql(f"SELECT hls_prefix FROM tracks WHERE id='{playable}'") == prefix
            print('PASS: real MP3 -> AAC HLS, shared-node playback, expired-lease recovery, ACL, share revocation, conversion failure and retry.')
        else:
            assert request('POST', f'/api/tracks/{track}/hls', token=a, expected=202)['preparation'] == 'queued'
            request('GET', f'/api/tracks/{track}/hls/index.m3u8', token=a, expected=409)
        assert request("GET", "/api/unknown", expected=404) == {"error": "not_found"}
        if backend_image:
            diagnostics = subprocess.check_output(['docker', 'logs', containers[0]], stderr=subprocess.STDOUT, text=True)
        else:
            log.flush()
            diagnostics = Path(log.name).read_text(encoding="utf-8")
        assert "Request infrastructure failure: DatabaseUnavailable" in diagnostics
        assert "SQLSTATE 42P01" in diagnostics
        assert "Request infrastructure failure: StorageUnavailable" in diagnostics
        assert "Track storage upload failed: StorageRejected" in diagnostics
        print("PASS: migrations preserve legacy rows; sessions, default playlists, ACL, track upload, covers, sharing and rollback checked.")
    finally:
        release_download.set()
        for name in containers:
            subprocess.run(['docker', 'rm', '-f', name], check=True, stdout=subprocess.DEVNULL)
        if server:
            server.terminate()
            server.wait(timeout=10)
        if log:
            log.close()
        storage.shutdown()
        storage.server_close()
        # This randomly named project is created above; never target user volumes.
        docker("down", "--volumes", "--remove-orphans")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--optimize", choices=("Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"), default="Debug")
    parser.add_argument('--backend-image', help='Use a prebuilt backend image including FFmpeg; also test real HLS on multiple nodes.')
    args = parser.parse_args()
    run_checks(args.optimize, args.backend_image)
