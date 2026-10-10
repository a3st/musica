"""Обработка настоящих MP3 и artwork в одноразовой БД с тестовым S3."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import uuid

from support import available_port, wait_for


def check_track_metadata(api_request, execute_sql, env, executable, backend, objects, block_artwork, optimize):
    """Проверяет извлечение, доступ, сумму плейлиста, смену аренды и удаление обложек."""
    ffmpeg = env.get('FFMPEG_PATH') or shutil.which('ffmpeg')
    if not ffmpeg and os.name == 'nt':
        candidate = Path('C:/Program Files/FFmpeg/bin/ffmpeg.exe')
        if candidate.is_file():
            ffmpeg = str(candidate)
    if not ffmpeg:
        raise RuntimeError('Metadata integration requires FFmpeg; set FFMPEG_PATH')
    ffprobe = env.get('FFPROBE_PATH') or str(Path(ffmpeg).with_name('ffprobe.exe' if os.name == 'nt' else 'ffprobe'))
    scratch = backend / '.zig-cache' / ('metadata-test-' + uuid.uuid4().hex)
    scratch.mkdir()

    def run_ffmpeg(*arguments):
        """Создаёт локальные медиа-фикстуры, без shell и внешней сети."""
        subprocess.run([ffmpeg, '-v', 'error', '-nostdin', '-y', *arguments], cwd=scratch, check=True)

    run_ffmpeg('-f', 'lavfi', '-i', 'color=c=blue:s=800x800', '-frames:v', '1', 'cover.jpg')
    run_ffmpeg('-f', 'lavfi', '-i', 'sine=frequency=440:duration=3.4', '-i', 'cover.jpg',
               '-map', '0:a', '-map', '1:v', '-c:a', 'libmp3lame', '-c:v', 'copy',
               '-disposition:v', 'attached_pic', '-id3v2_version', '3', 'with-artwork.mp3')
    run_ffmpeg('-f', 'lavfi', '-i', 'sine=frequency=220:duration=2.2', '-c:a', 'libmp3lame', 'plain.mp3')
    owner = api_request('POST', '/api/auth/register', {'username': 'metadata_owner', 'password': 'metadata-integration-password'}, expected=201)
    viewer = api_request('POST', '/api/auth/register', {'username': 'metadata_viewer', 'password': 'metadata-integration-password'}, expected=201)
    token = owner['token']
    default = api_request('GET', '/api/users/me', token=token)['default_playlist_id']
    # Earlier API checks intentionally uploaded invalid audio; keep this worker's queue isolated.
    execute_sql("UPDATE public.jobs SET state='failed', lease_until=NULL WHERE kind='inspect_track'")

    def create_track(name, file):
        """Создаёт и загружает реальный исходник через обычный API."""
        track = api_request('POST', '/api/tracks', {'title': name, 'artist': 'Fixture'}, token=token, expected=201)['id']
        api_request('PUT', f'/api/tracks/{track}/file', (scratch / file).read_bytes(), token=token, mime='audio/mpeg')
        assert execute_sql(f"SELECT state FROM public.jobs WHERE kind='inspect_track' AND dedupe_key='{track}'") == 'queued'
        return track

    def metadata(track):
        """Читает опубликованные метаданные из HTTP-ноды без worker."""
        return next(t for t in api_request('GET', '/api/playlists/' + default, token=token)['tracks'] if t['id'] == track)

    track = create_track('Embedded cover', 'with-artwork.mp3')
    plain = create_track('No cover', 'plain.mp3')
    assert metadata(track)['duration_seconds'] is None and metadata(track)['artwork_key'] is None
    api_request('GET', f'/api/tracks/{track}/artwork', token=token, expected=404)
    arrived, release = block_artwork(f'/uploads/tracks/{track}/artwork/')
    workers = []
    logs = []

    def start_worker():
        """Запускает отдельную ноду обработки с общими БД и S3."""
        log = (scratch / f'worker-{len(workers)}.log').open('w', encoding='utf-8')
        logs.append(log)
        worker_env = dict(env, HTTP_PORT=str(available_port()), TRACK_METADATA_WORKER_ENABLED='true',
                          TRACK_METADATA_TMP_DIR=str(scratch / 'worker'), FFMPEG_PATH=ffmpeg, FFPROBE_PATH=ffprobe)
        process = subprocess.Popen([str(executable)], cwd=backend, env=worker_env, stdout=log, stderr=log)
        workers.append(process)
        return process

    def completed(track):
        """Ожидает завершения inspect_track с диагностикой состояния БД."""
        return wait_for(lambda: execute_sql(f"SELECT state FROM public.jobs WHERE kind='inspect_track' AND dedupe_key='{track}'"),
                        lambda state: state == 'completed', description='track metadata completion')

    try:
        start_worker()
        assert arrived.wait(10), 'metadata worker did not upload artwork'
        first_attempt = execute_sql(f"SELECT attempt_id FROM public.jobs WHERE kind='inspect_track' AND dedupe_key='{track}'")
        execute_sql(f"UPDATE public.jobs SET lease_until=clock_timestamp()-interval '1 second' WHERE kind='inspect_track' AND dedupe_key='{track}'")
        start_worker()
        completed(track)
        completed(plain)
        release.set()
        wait_for(lambda: [key for key in objects if key.startswith(f'/uploads/tracks/{track}/artwork/')],
                 lambda keys: len(keys) == 2, description='stale artwork upload finishes')
        first = metadata(track)
        assert first['status'] == 'ready', 'metadata publication must not require HLS'
        assert first['duration_seconds'] == 3
        assert first['artwork_key'].startswith(f'tracks/{track}/artwork/')
        uuid.UUID(Path(first['artwork_key']).stem)
        assert metadata(plain)['duration_seconds'] == 2 and metadata(plain)['artwork_key'] is None
        assert execute_sql(f"SELECT attempt_id FROM public.jobs WHERE kind='inspect_track' AND dedupe_key='{track}'") != first_attempt
        artwork = api_request('GET', f'/api/tracks/{track}/artwork?v=ignored', token=token, raw=True)
        assert artwork.startswith(b'\xff\xd8')
        saved = scratch / 'normalized.jpg'
        saved.write_bytes(artwork)
        dimensions = json.loads(subprocess.check_output([ffprobe, '-v', 'error', '-show_entries', 'stream=width,height', '-of', 'json', str(saved)]))['streams'][0]
        assert dimensions['width'] <= 600 and dimensions['height'] <= 600
        api_request('GET', f'/api/tracks/{track}/artwork', token=viewer['token'], expected=404)
        api_request('GET', f'/api/tracks/{track}/artwork', expected=404)
        api_request('GET', f'/api/tracks/{plain}/artwork', token=token, expected=404)
        playlist = api_request('POST', '/api/playlists', {'title': 'Metadata mix'}, token=token, expected=201)['id']
        path = '/api/playlists/' + playlist
        for item in [track, plain]:
            api_request('PUT', path + '/tracks/' + item, token=token, expected=204)
        details = api_request('GET', path, token=token)
        assert details['track_count'] == 2 and details['duration_seconds'] == 5 and details['duration_complete'] is True
        summary = next(p for p in api_request('GET', '/api/playlists', token=token) if p['id'] == playlist)
        assert summary['duration_seconds'] == 5 and summary['duration_complete'] is True
        member = path + '/members/' + viewer['user_id']
        api_request('PUT', member, {'role': 'viewer'}, token=token, expected=204)
        assert api_request('GET', f'/api/tracks/{track}/artwork', token=viewer['token'], raw=True) == artwork
        api_request('DELETE', member, token=token, expected=204)
        api_request('GET', f'/api/tracks/{track}/artwork', token=viewer['token'], expected=404)
        api_request('PUT', path, {'title': 'Metadata mix', 'visibility': 'public'}, token=token, expected=204)
        assert api_request('GET', f'/api/tracks/{track}/artwork', raw=True) == artwork
        api_request('PUT', path, {'title': 'Metadata mix', 'visibility': 'unlisted'}, token=token, expected=204)
        shared = api_request('POST', path + '/share-link', token=token)['path'].rsplit('/', 1)[1]
        assert api_request('GET', f'/api/tracks/{track}/artwork?share_token={shared}', raw=True) == artwork
        api_request('DELETE', path + '/share-link', token=token, expected=204)
        api_request('GET', f'/api/tracks/{track}/artwork?share_token={shared}', expected=404)
        api_request('DELETE', path + '/tracks/' + plain, token=token, expected=204)
        assert api_request('GET', path, token=token)['duration_seconds'] == 3
        pending = api_request('POST', '/api/tracks', {'title': 'Pending duration', 'artist': 'Fixture'}, token=token, expected=201)['id']
        api_request('PUT', path + '/tracks/' + pending, token=token, expected=204)
        assert api_request('GET', path, token=token)['duration_complete'] is False
        assert api_request('GET', path, token=token)['duration_seconds'] == 3
        for process in workers:
            process.terminate()
            process.wait(timeout=10)
        assert metadata(track)['artwork_key'] == first['artwork_key'], 'stale attempt must not replace published artwork'
        api_request('DELETE', '/api/tracks/' + track, token=token, expected=204)
        execute_sql("UPDATE public.jobs SET available_at=now() WHERE kind='delete_s3_objects' AND state='queued'")
        wait_for(lambda: [key for key in objects if key.startswith(f'/uploads/tracks/{track}/')],
                 lambda keys: not keys, description='published and stale artwork cleanup')
        print('PASS: real MP3 seconds, normalized UUID artwork, lease fencing, private/public/link/member ACL, playlist totals and S3 cleanup.')
    finally:
        release.set()
        for process in workers:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
        for log in logs:
            log.close()
