"""API and migration checks in a disposable PostgreSQL; no user DB is touched.

Run from the repository root: python backend/tests/api_integration.py
Requires Python 3, Docker Compose, Zig 0.16 and the postgres:17-bookworm image.
The S3 endpoint is an in-process mock; SigV4 has separate Zig tests.
"""
import argparse
import hashlib
import hmac
import json
import os
import subprocess
import threading
import time
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from support import available_port, wait_for

ROOT = Path(__file__).resolve().parents[2]
BACKEND = ROOT / "backend"


def run_api_checks(optimize="Debug", backend_image=None):
    """Проверяет API на отдельной БД и гарантирует освобождение созданных ресурсов."""
    project = "musica-api-test-" + uuid.uuid4().hex[:8]
    env = os.environ.copy()
    # A developer's bootstrap settings must not create extra users in the fixture DB.
    env.pop("BOOTSTRAP_ADMIN_USERNAME", None)
    env.pop("BOOTSTRAP_ADMIN_PASSWORD", None)
    env.update(
        REGISTRATION_ENABLED="true",
        DB_NAME="musica",
        DB_USER="musica",
        DB_PASSWORD="test-db-password",
        DB_PORT="0",
        S3_ACCESS_KEY_ID="test-access",
        S3_SECRET_ACCESS_KEY="test-secret",
        S3_REGION="us-east-1",
        S3_BUCKET="uploads",
        AUTH_COOKIE_SECURE="false",
        SHARED_TRACK_RETENTION_SECONDS="604800",
    )
    compose = ["docker", "compose", "--env-file", str(ROOT / ".env.docker.example"), "-p", project]

    def run_compose(*args):
        """Выполняет Compose-команду только в случайно названном тестовом проекте."""
        return subprocess.check_output(compose + list(args), cwd=ROOT, env=env, text=True).strip()

    def execute_sql(query):
        """Выполняет SQL в одноразовой тестовой БД и возвращает текстовый результат."""
        return run_compose(
            "exec",
            "-T",
            "postgres",
            "psql",
            "-U",
            "musica",
            "-d",
            "musica",
            "-v",
            "ON_ERROR_STOP=1",
            "-At",
            "-c",
            query,
        )

    objects = {}
    blocked_path = None
    upload_arrived = threading.Event()
    release_upload = threading.Event()
    reject_upload = False
    reject_read = False
    reject_delete = False
    blocked_get_path = None
    download_arrived = threading.Event()
    release_download = threading.Event()

    def verify_s3_signature(handler, body):
        """Независимо проверяет SigV4 и хеш тела каждого запроса к тестовому S3."""
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

    class S3RequestHandler(BaseHTTPRequestHandler):
        """Локальное хранилище с управляемыми отказами и задержками запросов."""
        protocol_version = "HTTP/1.1"

        def handle(self):
            try:
                super().handle()
            except (ConnectionResetError, ConnectionAbortedError):
                pass  # Cancellation or shutdown closes persistent connections.

        def do_DELETE(self):
            verify_s3_signature(self, b'')
            if not reject_delete:
                objects.pop(self.path, None)
            self.send_response(503 if reject_delete else 204)
            if reject_delete:
                self.send_header('Content-Length', '0')
            self.end_headers()

        def do_PUT(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            verify_s3_signature(self, body)
            if reject_upload:
                self.send_response(503)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if blocked_path and self.path.startswith(blocked_path) and not upload_arrived.is_set():
                upload_arrived.set()
                assert release_upload.wait(10), "test did not release the S3 upload"
            objects[self.path] = body
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self):
            verify_s3_signature(self, b'')
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

    storage = ThreadingHTTPServer(("0.0.0.0" if backend_image else "127.0.0.1", 0), S3RequestHandler)
    threading.Thread(target=storage.serve_forever, daemon=True).start()
    server = None
    log = None
    containers = []

    def start_backend_node(worker):
        """Запускает HTTP-ноду в тестовой сети с общими PostgreSQL и S3."""
        name = project + '-node-' + str(len(containers))
        node_env = dict(
            REGISTRATION_ENABLED='true',
            HTTP_HOST='0.0.0.0',
            HTTP_PORT='8080',
            DB_HOST='postgres',
            DB_PORT='5432',
            DB_NAME='musica',
            DB_USER='musica',
            DB_PASSWORD='test-db-password',
            S3_ENDPOINT=f'http://host.docker.internal:{storage.server_port}',
            S3_REGION='us-east-1',
            S3_BUCKET='uploads',
            S3_ACCESS_KEY_ID='test-access',
            S3_SECRET_ACCESS_KEY='test-secret',
            HLS_WORKER_ENABLED=str(worker).lower(),
            SPOTIFY_WORKER_ENABLED='false',
            TRACK_METADATA_WORKER_ENABLED='false',
        )
        command = [
            'docker', 'run', '-d', '--name', name,
            '--network', project + '_default',
            '-p', '127.0.0.1::8080',
            '--add-host', 'host.docker.internal:host-gateway',
        ]
        for key, value in node_env.items():
            command += ['-e', key + '=' + value]
        command += [backend_image]
        subprocess.check_output(command, text=True)
        containers.append(name)
        mapped = subprocess.check_output(['docker', 'port', name, '8080'], text=True).strip().rsplit(':', 1)[1]
        return f'http://127.0.0.1:{mapped}'

    try:
        run_compose("up", "-d", "--wait", "postgres")
        port = run_compose("port", "postgres", "5432").rsplit(":", 1)[1]
        run_compose(
            "exec",
            "-T",
            "postgres",
            "psql",
            "-U",
            "musica",
            "-d",
            "musica",
            "-v",
            "ON_ERROR_STOP=1",
            "-f",
            "/migrations/001_init.sql",
        )
        migrated_track = execute_sql(
            "WITH owner AS (INSERT INTO musica.users(username,kind) VALUES ('migration_fixture','system') RETURNING id) "
            "INSERT INTO musica.tracks(title,artist,owner_id,storage_bucket,object_key,status,content_type,size_bytes,uploaded_at) "
            "SELECT 'Migration fixture','Test',id,'historical','existing.mp3','ready','audio/mpeg',100,now() FROM owner RETURNING id::text"
        ).splitlines()[0]
        run_compose(
            "exec", "-T", "postgres", "psql", "-U", "musica", "-d", "musica",
            "-v", "ON_ERROR_STOP=1", "-f", "/migrations/002_track_metadata.sql",
        )
        assert json.loads(execute_sql(f"SELECT payload FROM public.jobs WHERE kind='inspect_track' AND dedupe_key='{migrated_track}'")) == {
            'track_id': migrated_track, 'bucket': 'historical', 'key': 'existing.mp3', 'size': 100,
        }
        execute_sql(f"DELETE FROM public.jobs WHERE kind='inspect_track' AND dedupe_key='{migrated_track}'; DELETE FROM musica.tracks WHERE id='{migrated_track}'; DELETE FROM musica.playlists WHERE owner_id=(SELECT id FROM musica.users WHERE username='migration_fixture'); DELETE FROM musica.users WHERE username='migration_fixture'")
        assert execute_sql((
            "SELECT string_agg(table_schema || '.' || table_name, ',' ORDER BY table_schema, "
            "table_name) FROM information_schema.tables WHERE table_schema IN ('musica','public') "
            "AND table_type='BASE TABLE'"
        )) == "musica.catalog_cache,musica.playlist_members,musica.playlists,musica.sessions,musica.track_playlists,musica.track_sources,musica.tracks,musica.users,public.jobs"
        # Application queries must work without musica in search_path; jobs must ignore shadow.jobs.
        execute_sql("CREATE SCHEMA shadow; CREATE TABLE shadow.jobs (LIKE public.jobs INCLUDING ALL); ALTER ROLE musica SET search_path=shadow,public")
        shadow_job = execute_sql((
            "INSERT INTO shadow.jobs (kind,payload) VALUES "
            "('delete_s3_objects','{\"bucket\":\"shadow\",\"keys\":[\"must-not-delete\"]}') "
            "RETURNING id::text"
        )).splitlines()[0]
        shadow_snapshot = execute_sql(f"SELECT row_to_json(j)::text FROM shadow.jobs j WHERE id='{shadow_job}'")
        custom_job = execute_sql("INSERT INTO public.jobs (kind,payload) VALUES ('custom_fixture','{\"arbitrary\":[1,true,\"value\"]}') RETURNING id::text").splitlines()[0]

        if not backend_image:
            subprocess.run(["zig", "build", "-Doptimize=" + optimize], cwd=BACKEND, check=True)
        http_port = available_port()
        env.update(
            HTTP_HOST="127.0.0.1",
            HTTP_PORT=str(http_port),
            DB_HOST="127.0.0.1",
            DB_PORT=port,
            S3_ENDPOINT=f"http://127.0.0.1:{storage.server_port}",
            HLS_WORKER_ENABLED='false',
            SPOTIFY_WORKER_ENABLED='false',
            TRACK_METADATA_WORKER_ENABLED='false',
        )
        executable = BACKEND / "zig-out" / "bin" / ("musica-backend.exe" if os.name == "nt" else "musica-backend")
        if backend_image:
            base = start_backend_node(False)
        else:
            log = (BACKEND / ".zig-cache" / "api-integration.log").open("w", encoding="utf-8")
            server = subprocess.Popen([str(executable)], cwd=BACKEND, env=env, stdout=log, stderr=log)
            base = f"http://127.0.0.1:{http_port}"

        def api_request(
            method,
            path,
            body=None,
            token=None,
            expected=200,
            mime="application/json",
            raw=False,
            node=None,
            cookie=None,
            origin=None,
        ):
            """Вызывает API и проверяет статус, кеширование, MIME-тип и cookie сессии."""
            headers = {"Content-Type": mime}
            if token:
                headers["Authorization"] = "Bearer " + token
            if cookie:
                headers['Cookie'] = 'musica_session=' + cookie
            if origin:
                headers['Origin'] = origin
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
                    assert response.headers.get('Content-Type') == ('image/jpeg' if '/artwork' in path else 'image/png' if path.endswith('/image') else 'application/vnd.apple.mpegurl' if 'index.m3u8' in path else 'video/mp2t')
                if path in ('/api/auth/register', '/api/auth/login') and expected in (200, 201):
                    session = response.headers['Set-Cookie']
                    assert 'HttpOnly' in session and 'SameSite=Strict' in session and 'Path=/api' in session
                if path == '/api/auth/logout' and expected == 204:
                    assert 'Max-Age=0' in response.headers['Set-Cookie']
                return payload if raw else json.loads(payload) if payload else None

        for attempt in range(100):
            if server and server.poll() is not None:
                raise RuntimeError("backend exited; see backend/.zig-cache/api-integration.log")
            try:
                api_request("GET", "/api/health")
                break
            except OSError:
                time.sleep(0.1)
        else:
            raise RuntimeError("backend did not start")

        password = "integration-password-123"
        alice = api_request(
            "POST",
            "/api/auth/register",
            {"username": "alice", "password": password},
            expected=201,
        )
        bob = api_request("POST", "/api/auth/register", {"username": "bob", "password": password}, expected=201)
        a, b = alice["token"], bob["token"]
        default = api_request("GET", "/api/users/me", token=a)["default_playlist_id"]
        default_path = '/api/playlists/' + default
        original_default = api_request('GET', default_path, token=a)
        protected = {'error': 'default_playlist_protected'}
        assert api_request(
            'PUT',
            default_path,
            {'title': 'Renamed', 'description': 'Changed', 'visibility': 'public', 'tags': ['test']},
            token=a,
            expected=409,
        ) == protected
        assert api_request(
            'PUT',
            default_path + '/image',
            b'\x89PNG\r\n\x1a\nfixture',
            token=a,
            mime='image/png',
            expected=409,
        ) == protected
        assert api_request('POST', default_path + '/share-link', token=a, expected=409) == protected
        assert api_request('GET', default_path, token=a) == original_default
        assert not objects, 'protected default cover must not upload to S3'
        assert api_request('GET', '/api/users/me', cookie=a)['id'] == alice['user_id']
        api_request('GET', '/api/users/me', cookie='invalid', expected=401)
        api_request(
            'POST',
            '/api/tracks',
            {'title': 'CSRF', 'artist': 'Denied'},
            cookie=a,
            origin='http://evil.example',
            expected=403,
        )
        assert [p['id'] for p in api_request('GET', '/api/playlists', token=a)] == [default]
        api_request('GET', '/api/playlists', expected=401)
        execute_sql("ALTER TABLE musica.playlists RENAME TO temporarily_unavailable_playlists")
        try:
            failure = api_request("GET", "/api/users/me", token=a, expected=503 if optimize == "Debug" else 500)
            assert failure == {"error": "database_unavailable" if optimize == "Debug" else "internal_error"}
        finally:
            execute_sql("ALTER TABLE musica.temporarily_unavailable_playlists RENAME TO playlists")
        assert execute_sql("SELECT count(*) FROM musica.playlists p JOIN musica.users u ON u.id=p.owner_id WHERE p.is_default AND u.kind='user'") == "2"
        assert execute_sql("SELECT count(*) FROM musica.sessions WHERE length(token_hash)=64") == "2"
        assert execute_sql(f"SELECT count(*) FROM musica.sessions WHERE token_hash='{a}'") == "0"
        api_request("POST", "/api/auth/register", {"username": "alice", "password": password}, expected=409)
        assert execute_sql("SELECT count(*) FROM musica.playlists p JOIN musica.users u ON u.id=p.owner_id WHERE p.is_default AND u.kind='user'") == "2"
        api_request(
            "POST",
            "/api/auth/login",
            {"username": "alice", "password": "incorrect-password"},
            expected=401,
        )
        api_request("POST", "/api/auth/login", {"username": "missing", "password": password}, expected=401)
        login = api_request("POST", "/api/auth/login", {"username": "alice", "password": password})
        api_request("POST", "/api/auth/logout", cookie=login["token"], origin=base, expected=204)
        api_request("GET", "/api/users/me", token=login["token"], expected=401)
        execute_sql(f"UPDATE musica.sessions SET expires_at=now()-interval '1 second' WHERE user_id='{bob['user_id']}'")
        api_request("GET", "/api/users/me", token=b, expected=401)
        b = api_request("POST", "/api/auth/login", {"username": "bob", "password": password})["token"]
        api_request("GET", f"/api/playlists/{default}", expected=404)
        api_request("GET", f"/api/playlists/{default}", token=b, expected=404)
        created = api_request("POST", "/api/tracks", {"title": "Track", "artist": "Artist"}, token=a, expected=201)
        assert created["status"] == "pending"
        track = created["id"]
        assert execute_sql((
            f"SELECT storage_bucket || '/' || object_key FROM musica.tracks WHERE id='{track}' AND "
            f"status='pending' AND content_type IS NULL AND size_bytes IS NULL AND uploaded_at IS "
            f"NULL"
        )) == f"uploads/tracks/{track}/source"
        empty_track = api_request(
            "POST",
            "/api/tracks",
            {"playlist_ids": [], "title": "Empty list", "artist": "Artist"},
            token=a,
            expected=201,
        )["id"]
        assert {t["id"] for t in api_request(
            "GET",
            f"/api/playlists/{default}",
            token=a,
        )["tracks"]} == {track, empty_track}
        api_request("PUT", f"/api/tracks/{track}/file", b"audio", token=b, expected=404, mime="audio/mpeg")
        assert not objects
        blocked_path = f"/uploads/tracks/{track}/source"
        with ThreadPoolExecutor(max_workers=1) as executor:
            uploading = executor.submit(
                api_request,
                "PUT",
                f"/api/tracks/{track}/file",
                b"audio",
                token=a,
                mime="audio/mpeg",
            )
            try:
                assert upload_arrived.wait(5), "first upload did not reach S3"
                assert execute_sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='musica' AND state='idle in transaction'") == '0'
                api_request("DELETE", f"/api/tracks/{track}", token=a, expected=409)
                busy = api_request(
                    "PUT",
                    f"/api/tracks/{track}/file",
                    b"other audio",
                    token=a,
                    expected=409,
                    mime="audio/mpeg",
                )
                assert busy == {"error": "upload_in_progress"}
            finally:
                release_upload.set()
            result = uploading.result(timeout=10)
            assert result["status"] == "ready"
            assert result['object_key'].rsplit('/', 1)[0] == f'tracks/{track}/source'
            uuid.UUID(result['object_key'].rsplit('/', 1)[1])
            source_track = '/' + result['bucket'] + '/' + result['object_key']
        blocked_path = None
        assert objects[source_track] == b"audio"
        api_request("PUT", f"/api/tracks/{track}/file", b"audio", token=a, expected=409, mime="audio/mpeg")
        preserved = api_request(
            "POST",
            "/api/tracks",
            {"title": "Historical location", "artist": "Artist"},
            token=a,
            expected=201,
        )["id"]
        # Simulate a track created under an older bucket/key configuration.
        execute_sql(f"UPDATE musica.tracks SET storage_bucket='historical-uploads', object_key='tracks/stored-key' WHERE id='{preserved}'")
        reject_upload = True
        failure = api_request(
            "PUT",
            f"/api/tracks/{preserved}/file",
            b"audio",
            token=a,
            expected=502 if optimize == "Debug" else 500,
            mime="audio/mpeg",
        )
        assert failure == {"error": "storage_unavailable" if optimize == "Debug" else "internal_error"}
        assert execute_sql((
            f"SELECT storage_bucket || '/' || object_key FROM musica.tracks WHERE id='{preserved}' "
            f"AND status='pending' AND content_type IS NULL AND size_bytes IS NULL AND uploaded_at "
            f"IS NULL"
        )) == "historical-uploads/tracks/stored-key"
        reject_upload = False
        uploaded = api_request(
            "PUT",
            f"/api/tracks/{preserved.upper()}/file",
            b"audio",
            token=a,
            mime="audio/mpeg",
        )
        assert uploaded["bucket"] == "historical-uploads" and uploaded["object_key"].startswith("tracks/stored-key/")
        assert objects["/historical-uploads/" + uploaded["object_key"]] == b"audio"
        assert execute_sql(f"SELECT storage_bucket || '/' || object_key FROM musica.tracks WHERE id='{preserved}' AND status='ready'") == "historical-uploads/" + uploaded["object_key"]
        # An expired uploader must never overwrite or publish a replacement attempt.
        stale = api_request(
            "POST",
            "/api/tracks",
            {"title": "Expired upload", "artist": "Test"},
            token=a,
            expected=201,
        )["id"]
        blocked_path = f"/uploads/tracks/{stale}/source"
        upload_arrived.clear()
        release_upload.clear()
        with ThreadPoolExecutor(max_workers=1) as executor:
            old = executor.submit(
                api_request,
                "PUT",
                f"/api/tracks/{stale}/file",
                b"old",
                token=a,
                mime="audio/mpeg",
                expected=409,
            )
            try:
                assert upload_arrived.wait(5)
                execute_sql(f"UPDATE public.jobs SET lease_until=now()-interval '1 second' WHERE kind='upload_track' AND dedupe_key='{stale}'")
                replacement = api_request("PUT", f"/api/tracks/{stale}/file", b"new", token=a, mime="audio/mpeg")
            finally:
                release_upload.set()
            assert old.result(timeout=10) == {"error": "upload_in_progress"}
        blocked_path = None
        replacement_path = "/" + replacement["bucket"] + "/" + replacement["object_key"]
        assert objects[replacement_path] == b"new"
        assert execute_sql(f"SELECT object_key FROM musica.tracks WHERE id='{stale}' AND status='ready' ") == replacement["object_key"]
        orphan = next(key for key in objects if key.startswith(f"/uploads/tracks/{stale}/source/") and key != replacement_path)
        execute_sql("UPDATE public.jobs SET available_at=now()-interval '1 second' WHERE kind='delete_s3_objects' AND state='queued'")
        wait_for(
            lambda: orphan in objects,
            lambda exists: not exists,
            timeout_seconds=6,
            description="expired upload object cleanup",
        )
        assert replacement_path in objects
        playlist = api_request("POST", "/api/playlists", {"title": "Playlist"}, token=a, expected=201)["id"]
        path = f"/api/playlists/{playlist}"
        api_request("GET", path, expected=404)
        api_request("GET", path, token=b, expected=404)
        member = path + "/members/" + bob["user_id"]
        api_request("PUT", member, {"role": "viewer"}, token=a, expected=204)
        assert next(p for p in api_request('GET', '/api/playlists', token=b) if p['id'] == playlist)['role'] == 'viewer'
        api_request("GET", path, token=b)
        api_request("PUT", path, {"title": "Denied"}, token=b, expected=404)
        api_request("PUT", path + "/tracks/" + track, token=b, expected=404)
        api_request("PUT", path + "/image", b"\x89PNG\r\n\x1a\nfixture", token=b, expected=404, mime="image/png")
        api_request("PUT", member, {"role": "editor"}, token=a, expected=204)
        blocked_path = f"/uploads/playlists/{playlist}/"
        upload_arrived.clear()
        release_upload.clear()
        cover_keys_before = set(objects)
        with ThreadPoolExecutor(max_workers=1) as executor:
            revoked_cover = executor.submit(
                api_request,
                "PUT",
                path + "/image",
                b"\x89PNG\r\n\x1a\nrevoked",
                token=b,
                mime="image/png",
                expected=404,
            )
            try:
                assert upload_arrived.wait(5)
                assert execute_sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='musica' AND state='idle in transaction'") == '0'
                api_request("DELETE", member, token=a, expected=204)
            finally:
                release_upload.set()
            revoked_cover.result(timeout=10)
        blocked_path = None
        assert api_request("GET", path, token=a)["image_key"] is None
        orphan_cover = next(key for key in objects if key not in cover_keys_before and key.startswith(f"/uploads/playlists/{playlist}/"))
        execute_sql("UPDATE public.jobs SET available_at=now()-interval '1 second' WHERE kind='delete_s3_objects' AND state='queued'")
        wait_for(
            lambda: orphan_cover in objects,
            lambda exists: not exists,
            timeout_seconds=6,
            description="unpublished cover cleanup",
        )
        api_request("PUT", member, {"role": "editor"}, token=a, expected=204)
        api_request(
            "PUT",
            path,
            {"title": "Renamed", "description": "Description", "tags": ["rock", "live"]},
            token=b,
            expected=204,
        )
        metadata = api_request("GET", path, token=a)
        assert "artist" not in metadata
        assert metadata["title"] == "Renamed" and metadata["tags"] == ["rock", "live"]
        api_request("PUT", member, {"role": "viewer"}, token=b, expected=404)
        api_request("PUT", path + "/tracks/" + track, token=b, expected=404)
        api_request("PUT", path + "/tracks/" + track, token=a, expected=204)
        api_request("PUT", path + "/tracks/" + track, token=a, expected=204)
        assert len(api_request("GET", path, token=b)["tracks"]) == 1
        api_request("DELETE", f"/api/playlists/{default}/tracks/{track}", token=b, expected=404)
        api_request(
            "PUT",
            f"/api/playlists/{default}",
            {"title": "Uploads", "visibility": "public"},
            token=a,
            expected=409,
        )
        count = execute_sql("SELECT count(*) FROM musica.tracks")
        api_request(
            "POST",
            "/api/tracks",
            {"playlist_ids": [playlist, str(uuid.uuid4())], "title": "Rollback", "artist": "Artist"},
            token=a,
            expected=404,
        )
        assert execute_sql("SELECT count(*) FROM musica.tracks") == count
        combined = api_request(
            "POST",
            "/api/tracks",
            {"playlist_ids": [playlist], "title": "Both playlists", "artist": "Artist"},
            token=a,
            expected=201,
        )["id"]
        assert execute_sql(f"SELECT count(*) FROM musica.track_playlists WHERE track_id='{combined}'") == "2"
        cover = b"\x89PNG\r\n\x1a\nfixture"
        image = api_request("PUT", path + "/image", cover, token=b, mime="image/png")
        assert objects["/uploads/" + image["image_key"]] == cover
        assert api_request("GET", path, token=a)["image_key"] == image["image_key"]
        assert api_request('GET', path + '/image', cookie=a, raw=True) == cover
        api_request('GET', path + '/image', expected=404)
        api_request("PUT", path + "/image", b"html", token=a, expected=400, mime="image/png")
        api_request("PUT", path, {"title": "Public", "visibility": "public"}, token=a, expected=204)
        api_request("GET", path)
        assert api_request('GET', path + '/image', raw=True) == cover
        api_request("PUT", path, {"title": "Unlisted", "visibility": "unlisted"}, token=a, expected=204)
        api_request("GET", path, expected=404)
        link = api_request("POST", path + "/share-link", token=a)["path"]
        api_request("GET", link)
        rotated = api_request("POST", path + "/share-link", token=a)["path"]
        api_request("GET", link, expected=404)
        api_request("GET", rotated)
        api_request("DELETE", path + "/share-link", token=a, expected=204)
        api_request("GET", rotated, expected=404)
        api_request("DELETE", member, token=a, expected=204)
        api_request("GET", path, token=b, expected=404)
        pending_hls = f'/api/tracks/{empty_track}/hls'
        assert api_request('POST', pending_hls, token=a, expected=409) == {'error': 'track_not_uploaded'}
        api_request('GET', pending_hls + '/index.m3u8', token=a, expected=409)
        assert api_request('GET', pending_hls + '/status', token=a) == {'status': 'pending', 'preparation': None}
        api_request('POST', f'/api/tracks/{track}/hls', token=b, expected=404)

        if backend_image:
            mp3 = subprocess.check_output(['docker', 'run', '--rm', '--entrypoint', 'ffmpeg', backend_image,
                                          '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=13',
                                          '-c:a', 'libmp3lame', '-f', 'mp3', 'pipe:1'])
            playable = api_request(
                'POST',
                '/api/tracks',
                {'title': 'HLS fixture', 'artist': 'Test'},
                token=a,
                expected=201,
            )['id']
            uploaded_hls = api_request('PUT', f'/api/tracks/{playable}/file', mp3, token=a, mime='audio/mpeg')
            hls = f'/api/tracks/{playable}/hls'
            assert api_request('POST', hls, token=a, expected=202) == {'status': 'ready', 'preparation': 'queued'}
            assert api_request('POST', hls, token=a, expected=202)['preparation'] == 'queued'
            assert execute_sql(f"SELECT count(*) FROM public.jobs WHERE kind='prepare_hls' AND dedupe_key='{playable}'") == '1'
            playable_source = '/' + uploaded_hls['bucket'] + '/' + uploaded_hls['object_key']
            blocked_get_path = playable_source
            first_node = start_backend_node(True)
            assert download_arrived.wait(15), 'worker did not download original'
            api_request('DELETE', '/api/tracks/' + playable, token=a, expected=409)
            first_attempt = execute_sql(f"SELECT attempt_id FROM public.jobs WHERE kind='prepare_hls' AND dedupe_key='{playable}'")
            assert api_request('POST', hls, token=a, expected=202)['preparation'] == 'processing'
            assert execute_sql(f"SELECT attempt_id FROM public.jobs WHERE kind='prepare_hls' AND dedupe_key='{playable}'") == first_attempt
            # Simulate a node that stopped renewing its lease. A different node must claim it.
            execute_sql(f"UPDATE public.jobs SET lease_until=now()-interval '1 second' WHERE kind='prepare_hls' AND dedupe_key='{playable}'")
            second_node = start_backend_node(True)

            def wait_for_hls_state(track_path, expected):
                """Ожидает состояние задачи HLS с диагностикой последнего ответа API."""
                return wait_for(
                    lambda: api_request('GET', track_path + '/status', token=a),
                    lambda state: state['preparation'] == expected,
                    description=f'HLS preparation {expected} for {track_path}',
                )

            assert wait_for_hls_state(hls, 'completed')['status'] == 'streamed'
            current_attempt = execute_sql(f"SELECT attempt_id FROM public.jobs WHERE kind='prepare_hls' AND dedupe_key='{playable}'")
            assert current_attempt != first_attempt
            prefix = execute_sql(f"SELECT hls_prefix FROM musica.tracks WHERE id='{playable}'")
            assert prefix.endswith(current_attempt)
            release_download.set()
            # Playback uses the HTTP node with its worker disabled, independent of preparation.
            manifest = api_request('GET', hls + '/index.m3u8', token=a, raw=True).decode()
            assert '#EXT-X-PLAYLIST-TYPE:VOD' in manifest and '#EXT-X-ENDLIST' in manifest
            segment_names = [line for line in manifest.splitlines() if line and not line.startswith('#')]
            assert len(segment_names) == 3, manifest
            segment_data = api_request('GET', hls + '/' + segment_names[0], token=a, raw=True, node=second_node)
            assert segment_data == objects[f'/uploads/{prefix}/segment-000000.ts']
            probe = subprocess.check_output(['docker', 'run', '--rm', '-i', '--entrypoint', 'ffprobe', backend_image,
                                             '-v', 'error', '-show_entries', 'stream=codec_name,codec_type',
                                             '-of', 'json', '-i', 'pipe:0'], input=segment_data)
            assert any(s['codec_name'] == 'aac' and s['codec_type'] == 'audio' for s in json.loads(probe)['streams'])
            assert api_request('POST', hls, token=a) == {'status': 'streamed', 'preparation': 'completed'}
            api_request('PUT', f'/api/tracks/{playable}/file', mp3, token=a, mime='audio/mpeg', expected=409)
            api_request('GET', hls + '/segments/segment-000003.ts', token=a, expected=404)
            api_request('GET', hls + '/segments/segment-00000a.ts', token=a, expected=404)
            api_request('GET', hls + '/index.m3u8', token=b, expected=404)
            api_request('GET', hls + '/' + segment_names[0], expected=404)
            reject_read = True
            try:
                failure = api_request(
                    'GET',
                    hls + '/' + segment_names[0],
                    token=a,
                    expected=502 if optimize == 'Debug' else 500,
                )
                assert failure == {'error': 'storage_unavailable' if optimize == 'Debug' else 'internal_error'}
            finally:
                reject_read = False
            api_request('PUT', path + '/tracks/' + playable, token=a, expected=204)
            api_request('PUT', member, {'role': 'viewer'}, token=a, expected=204)
            api_request('GET', hls + '/' + segment_names[0], token=b, raw=True)
            api_request('POST', hls, token=b, expected=404)
            api_request('DELETE', member, token=a, expected=204)
            api_request('GET', hls + '/' + segment_names[0], token=b, expected=404)
            api_request('PUT', path, {'title': 'Public', 'visibility': 'public'}, token=a, expected=204)
            api_request('GET', hls + '/index.m3u8', raw=True)
            api_request('PUT', path, {'title': 'Unlisted', 'visibility': 'unlisted'}, token=a, expected=204)
            shared = api_request('POST', path + '/share-link', token=a)['path'].rsplit('/', 1)[1]
            shared_manifest = api_request('GET', hls + '/index.m3u8?share_token=' + shared, raw=True).decode()
            shared_segment = next(line for line in shared_manifest.splitlines() if line.startswith('segments/'))
            assert shared_segment.endswith('?share_token=' + shared)
            api_request('GET', hls + '/' + shared_segment, raw=True)
            api_request('DELETE', path + '/share-link', token=a, expected=204)
            api_request('GET', hls + '/' + shared_segment, expected=404)
            # Invalid media never publishes streamed, and a retry reuses the job row.
            invalid_hls = f'/api/tracks/{track}/hls'
            api_request('POST', invalid_hls, token=a, expected=202)
            assert wait_for_hls_state(invalid_hls, 'failed')['status'] == 'ready'
            api_request('GET', invalid_hls + '/index.m3u8', token=a, expected=409)
            api_request('POST', invalid_hls, token=a, expected=202)
            assert wait_for_hls_state(invalid_hls, 'failed')['status'] == 'ready'
            assert execute_sql(f"SELECT count(*) FROM public.jobs WHERE kind='prepare_hls' AND dedupe_key='{track}'") == '1'
            for _ in range(100):
                first_logs = subprocess.check_output(
                    ['docker', 'logs', containers[1]],
                    stderr=subprocess.STDOUT,
                    text=True,
                )
                if 'LeaseLost' in first_logs:
                    break
                time.sleep(0.1)
            else:
                raise AssertionError('old worker did not reject its expired/replaced lease')
            assert execute_sql(f"SELECT hls_prefix FROM musica.tracks WHERE id='{playable}'") == prefix
            assert api_request('GET', hls + '/index.m3u8', cookie=a, raw=True).decode() == manifest
            api_request('DELETE', f'/api/playlists/{default}/tracks/{playable}', token=a, expected=204)
            for _ in range(200):
                if not any(key.startswith(f'/uploads/{prefix}/') or key == playable_source for key in objects):
                    break
                time.sleep(0.1)
            else:
                raise AssertionError('published HLS objects were not cleaned up')
            assert execute_sql(f"SELECT count(*) FROM public.jobs WHERE kind='prepare_hls' AND dedupe_key='{playable}'") == '0'
            api_request('GET', hls + '/index.m3u8', token=a, expected=404)
            print('PASS: real MP3 -> AAC HLS, shared-node playback, expired-lease recovery, ACL, share revocation, conversion failure and retry.')
        else:
            assert api_request(
                'POST',
                f'/api/tracks/{track}/hls',
                token=a,
                expected=202,
            )['preparation'] == 'queued'
            api_request('GET', f'/api/tracks/{track}/hls/index.m3u8', token=a, expected=409)

        execute_sql("UPDATE public.jobs SET available_at=now()-interval '1 second' WHERE kind='delete_s3_objects' AND state='queued'")
        # Unlinking an ordinary playlist retains the source; deleting from Uploads removes every link.
        doomed = api_request(
            'POST',
            '/api/tracks',
            {'title': 'Delete fixture', 'artist': 'Test', 'playlist_ids': [playlist]},
            token=a,
            expected=201,
        )['id']
        uploaded_doomed = api_request(
            'PUT',
            f'/api/tracks/{doomed}/file',
            b'delete fixture',
            token=a,
            mime='audio/mpeg',
        )
        source = '/' + uploaded_doomed['bucket'] + '/' + uploaded_doomed['object_key']
        api_request('DELETE', '/api/tracks/' + doomed, token=b, expected=404)
        api_request('DELETE', path + '/tracks/' + doomed, token=a, expected=204)
        assert source in objects and execute_sql(f"SELECT count(*) FROM musica.tracks WHERE id='{doomed}'") == '1'
        assert execute_sql(f"SELECT count(*) FROM musica.track_playlists WHERE track_id='{doomed}'") == '1'
        api_request('PUT', path + '/tracks/' + doomed, token=a, expected=204)
        reject_delete = True
        api_request('DELETE', f'/api/playlists/{default}/tracks/{doomed}', token=a, expected=204)
        assert execute_sql(f"SELECT count(*) FROM musica.tracks WHERE id='{doomed}'") == '0'
        assert execute_sql(f"SELECT count(*) FROM musica.track_playlists WHERE track_id='{doomed}'") == '0'
        wait_for(
            lambda: execute_sql("SELECT count(*) FROM public.jobs WHERE kind='delete_s3_objects' AND available_at>now()"),
            lambda count: count != '0',
            timeout_seconds=10,
            description='cleanup retry after S3 failure',
        )
        assert source in objects
        reject_delete = False
        execute_sql("UPDATE public.jobs SET available_at=now() WHERE kind='delete_s3_objects' AND state='queued'")
        api_request('DELETE', '/api/tracks/' + empty_track, token=a, expected=204)
        wait_for(
            lambda: (source in objects, execute_sql("SELECT count(*) FROM public.jobs WHERE kind='delete_s3_objects'")),
            lambda state: state == (False, '0'),
            timeout_seconds=15,
            description='cleanup completion after S3 recovery',
        )
        assert objects['/historical-uploads/' + uploaded['object_key']] == b'audio'
        api_request('DELETE', '/api/tracks/' + doomed, token=a, expected=404)
        # Playlist deletion revokes access and cleans covers without deleting its tracks.
        disposable = api_request(
            'POST',
            '/api/playlists',
            {'title': 'Delete me', 'visibility': 'unlisted'},
            token=a,
            expected=201,
        )['id']
        disposable_path = '/api/playlists/' + disposable
        kept_track = api_request(
            'POST',
            '/api/tracks',
            {'title': 'Keep me', 'artist': 'Artist', 'playlist_ids': [disposable]},
            token=a,
            expected=201,
        )['id']
        # Bodies larger than the preallocated 64 KiB buffers must still upload intact.
        kept_audio = b'keep-audio' * (128 * 1024 // len(b'keep-audio') + 1)
        kept_file = api_request('PUT', f'/api/tracks/{kept_track}/file', kept_audio, token=a, mime='audio/mpeg')
        assert execute_sql(f"SELECT size_bytes FROM musica.tracks WHERE id='{kept_track}'") == str(len(kept_audio))
        kept_object = '/uploads/' + kept_file['object_key']
        disposable_member = disposable_path + '/members/' + bob['user_id']
        api_request('DELETE', disposable_path, expected=401)
        api_request('DELETE', '/api/playlists/invalid', token=a, expected=400)
        api_request('DELETE', '/api/playlists/' + str(uuid.uuid4()), token=a, expected=404)
        for role in ('viewer', 'editor'):
            api_request('PUT', disposable_member, {'role': role}, token=a, expected=204)
            api_request('DELETE', disposable_path, token=b, expected=404)
        assert api_request(
            'DELETE',
            '/api/playlists/' + default,
            token=a,
            expected=409,
        ) == {'error': 'default_playlist_protected'}
        assert any(t['id'] == kept_track for t in api_request('GET', '/api/playlists/' + default, token=a)['tracks'])
        disposable_link = api_request('POST', disposable_path + '/share-link', token=a)['path']
        disposable_cover = api_request(
            'PUT',
            disposable_path + '/image',
            cover,
            token=a,
            mime='image/png',
        )['image_key']

        # A failure to enqueue cleanup must roll back the playlist and all its relationships.
        execute_sql((
            f"ALTER TABLE public.jobs ADD CONSTRAINT test_reject_cover_cleanup CHECK (kind <> "
            f"'delete_s3_objects' OR NOT (payload->'keys' @> '[\"{disposable_cover}\"]'::jsonb)) NOT "
            f"VALID"
        ))
        try:
            api_request('DELETE', disposable_path, token=a, expected=400)
            assert api_request('GET', disposable_path, token=b)['image_key'] == disposable_cover
            assert len(api_request('GET', disposable_link)['tracks']) == 1
            assert execute_sql(f"SELECT count(*) FROM musica.track_playlists WHERE playlist_id='{disposable}'") == '1'
            assert execute_sql(f"SELECT count(*) FROM musica.playlist_members WHERE playlist_id='{disposable}'") == '1'
        finally:
            execute_sql('ALTER TABLE public.jobs DROP CONSTRAINT test_reject_cover_cleanup')

        # An image upload in flight cannot publish after the playlist has been deleted.
        blocked_path = f'/uploads/playlists/{disposable}/'
        upload_arrived.clear()
        release_upload.clear()
        cover_keys_before = set(objects)
        with ThreadPoolExecutor(max_workers=1) as executor:
            deleted_cover = executor.submit(
                api_request,
                'PUT',
                disposable_path + '/image',
                cover,
                token=a,
                mime='image/png',
                expected=404,
            )
            try:
                assert upload_arrived.wait(5)
                api_request('DELETE', disposable_path, token=a, expected=204)
            finally:
                release_upload.set()
            deleted_cover.result(timeout=10)
        blocked_path = None
        unpublished_cover = next(k for k in objects if k not in cover_keys_before and k.startswith(f'/uploads/playlists/{disposable}/'))
        api_request('GET', disposable_path, token=a, expected=404)
        api_request('GET', disposable_path + '/image', token=a, expected=404)
        api_request('GET', disposable_link, expected=404)
        api_request('DELETE', disposable_path, token=a, expected=404)
        assert all(p['id'] != disposable for p in api_request('GET', '/api/playlists', token=b))
        assert execute_sql(f"SELECT count(*) FROM musica.track_playlists WHERE playlist_id='{disposable}'") == '0'
        assert execute_sql(f"SELECT count(*) FROM musica.playlist_members WHERE playlist_id='{disposable}'") == '0'
        assert any(t['id'] == kept_track for t in api_request('GET', '/api/playlists/' + default, token=a)['tracks'])
        execute_sql("UPDATE public.jobs SET available_at=now() WHERE kind='delete_s3_objects' AND state='queued'")
        wait_for(
            lambda: ('/uploads/' + disposable_cover in objects, unpublished_cover in objects),
            lambda state: state == (False, False),
            timeout_seconds=6,
            description='deleted playlist cover cleanup',
        )
        assert objects[kept_object] == kept_audio
        empty_playlist = api_request('POST', '/api/playlists', {'title': 'Empty'}, token=a, expected=201)['id']
        api_request('DELETE', '/api/playlists/' + empty_playlist, token=a, expected=204)
        print('PASS: owner-only playlist deletion, protected Uploads, preserved tracks, revoked sharing, atomic cleanup and in-flight cover uploads.')
        # A stopped worker leaves processing behind; the next worker must reclaim the expired lease.
        recovery_prefix = 'cleanup-recovery/' + str(uuid.uuid4())
        recovery_keys = [f'{recovery_prefix}/segment-{index:06d}.ts' for index in range(43)]
        for key in recovery_keys:
            objects['/uploads/' + key] = b'recover-deletion'
        recovery_payload = json.dumps({'bucket': 'uploads', 'keys': recovery_keys})
        recovered_cleanup = execute_sql(f"""
            INSERT INTO public.jobs (kind, state, attempt_id, attempts, lease_until, payload)
            VALUES (
                'delete_s3_objects', 'processing', gen_random_uuid(), 1,
                now() - interval '1 second', '{recovery_payload}'::jsonb
            )
            RETURNING id::text
        """).splitlines()[0]
        wait_for(
            lambda: execute_sql(f"SELECT count(*) FROM public.jobs WHERE id='{recovered_cleanup}'"),
            lambda count: count == '0',
            timeout_seconds=10,
            description='expired cleanup lease recovery',
        )
        assert all('/uploads/' + key not in objects for key in recovery_keys)
        print('PASS: expired processing cleanup is reclaimed and all 43 objects are deleted.')
        print('PASS: cookie sessions, CSRF, playlist listing, cover reads, unlink versus global delete, durable S3 cleanup and retries.')
        if not backend_image:
            subprocess.run(['zig', 'build', 'test-download-fixture'], cwd=BACKEND, check=True)
            from spotify_integration import check_spotify_import
            check_spotify_import(api_request, execute_sql, env, executable, BACKEND)

            def block_artwork(prefix):
                """Задерживает одну запись artwork для проверки смены аренды между нодами."""
                nonlocal blocked_path
                blocked_path = prefix
                upload_arrived.clear()
                release_upload.clear()
                return upload_arrived, release_upload

            from metadata_integration import check_track_metadata
            check_track_metadata(api_request, execute_sql, env, executable, BACKEND, objects, block_artwork, optimize)

        # Catalog fixtures are seeded only in the disposable database; no Apple request is needed.
        web_song = {
            'external_id': '123456', 'title': 'Web fixture (Live)', 'artist': 'Web artist',
            'album': 'Web album', 'duration_seconds': 123, 'artwork_url': None, 'store_url': None,
        }
        for key, value in [('itunes:search:US:Web fixture', [web_song]), ('itunes:lookup:US:123456', web_song)]:
            body = json.dumps(value)
            execute_sql(f"INSERT INTO musica.catalog_cache (key, body, expires_at) VALUES ('{key}', '{body}', clock_timestamp() + interval '10 minutes')")
        api_request('GET', '/api/web/search?q=Web%20fixture', expected=401)
        api_request('GET', '/api/web/search?q=x', token=a, expected=400)
        assert api_request('GET', '/api/web/search?q=Web%20fixture', token=a)['tracks'] == [web_song]
        api_request('POST', '/api/web/tracks', {'external_id': '123456'}, expected=401)
        api_request('POST', '/api/web/tracks', {'external_id': '123&other=1'}, token=a, expected=400)
        first_web = api_request('POST', '/api/web/tracks', {'external_id': '123456'}, token=a, expected=202)['id']
        second_web = api_request('POST', '/api/web/tracks', {'external_id': '123456'}, token=b, expected=202)['id']
        assert first_web == second_web
        assert execute_sql(f"SELECT count(*) FROM musica.track_sources WHERE provider='itunes' AND external_id='123456' AND track_id='{first_web}'") == '1'
        assert execute_sql(f"SELECT count(*) FROM public.jobs WHERE kind='download_track' AND dedupe_key='{first_web}'") == '1'
        assert execute_sql(f"SELECT u.kind FROM musica.users u JOIN musica.tracks t ON t.owner_id=u.id WHERE t.id='{first_web}'") == 'system'
        api_request('DELETE', '/api/tracks/' + first_web, token=a, expected=204)
        assert execute_sql(f"SELECT count(*) FROM musica.tracks WHERE id='{first_web}'") == '1'
        bob_default = api_request('GET', '/api/users/me', token=b)['default_playlist_id']
        assert any(t['id'] == first_web for t in api_request('GET', '/api/playlists/' + bob_default, token=b)['tracks'])
        print('PASS: Web search ACL/cache, verified catalog selection, shared ownership, deduplication and personal unlink.')
        assert api_request("GET", "/api/unknown", expected=404) == {"error": "not_found"}
        if backend_image:
            diagnostics = subprocess.check_output(
                ['docker', 'logs', containers[0]],
                stderr=subprocess.STDOUT,
                text=True,
            )
        else:
            log.flush()
            diagnostics = Path(log.name).read_text(encoding="utf-8")
        assert "Request infrastructure failure: DatabaseUnavailable" in diagnostics
        assert "SQLSTATE 42P01" in diagnostics
        assert "Request infrastructure failure: StorageUnavailable" in diagnostics
        assert "Track storage upload failed: StorageRejected" in diagnostics
        assert execute_sql(f"SELECT state FROM public.jobs WHERE id='{custom_job}'") == "queued"
        assert execute_sql(f"SELECT row_to_json(j)::text FROM shadow.jobs j WHERE id='{shadow_job}'") == shadow_snapshot
        print("PASS: public.jobs is used with a shadow table earlier in search_path; unrelated kinds are untouched.")
        print("PASS: fresh schema; sessions, default playlists, ACL, track upload, covers, sharing and rollback checked.")
    finally:
        release_upload.set()
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
        run_compose("down", "--volumes", "--remove-orphans")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--optimize",
        choices=("Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"),
        default="Debug",
    )
    parser.add_argument(
        '--backend-image',
        help='Use a prebuilt backend image including FFmpeg; also test real HLS on multiple nodes.',
    )
    args = parser.parse_args()
    run_api_checks(args.optimize, args.backend_image)
