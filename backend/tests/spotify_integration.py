"""Offline Spotify import checks; called against the disposable API test database."""
import json
import os
import subprocess
import time


def check_spotify(request, sql, env, executable, backend):
    password = 'spotify-integration-password'
    owner = request('POST', '/api/auth/register', {'username': 'spotify_owner', 'password': password}, expected=201)
    other = request('POST', '/api/auth/register', {'username': 'spotify_other', 'password': password}, expected=201)
    token = owner['token']
    uri = 'spotify:track:0123456789012345678901'
    song = {'title': 'Get Lucky', 'artist': 'Daft Punk', 'spotify_uri': uri}
    body = {'playlists': [{'title': 'Spotify mix', 'description': 'Imported', 'tracks': [song, song]}],
            'library': [song, {'title': 'Other song', 'artist': 'Other artist'}]}
    request('POST', '/api/spotify/import', body, expected=401)
    request('POST', '/api/spotify/import', {}, token=token, expected=400)
    request('POST', '/api/spotify/import', {'library': [song, {'title': '', 'artist': 'Artist'}]}, token=token, expected=400)
    assert sql(f"SELECT count(*) FROM musica.tracks WHERE owner_id='{owner['user_id']}'") == '0'
    imported = request('POST', '/api/spotify/import', body, token=token, expected=202)
    assert imported['tracks'] == 2 and len(imported['playlists']) == 1
    assert 'id' not in imported
    default = request('GET', '/api/users/me', token=token)['default_playlist_id']
    def status():
        return {'tracks': json.loads(sql(f"SELECT json_agg(json_build_object('id',t.id,'status',t.status,'download',j.state,'preparation',h.state)) FROM musica.tracks t JOIN musica.track_playlists tp ON tp.track_id=t.id LEFT JOIN public.jobs j ON j.kind='download_track' AND j.dedupe_key=t.id::text LEFT JOIN public.jobs h ON h.kind='prepare_hls' AND h.dedupe_key=t.id::text WHERE tp.playlist_id='{default}'"))}
    state = status()
    assert len(state['tracks']) == 2 and {t['download'] for t in state['tracks']} == {'queued'}
    playlist = request('GET', '/api/playlists/' + imported['playlists'][0], token=token)
    assert playlist['visibility'] == 'private' and len(playlist['tracks']) == 1
    assert len(request('GET', '/api/playlists/' + default, token=token)['tracks']) == 2
    assert sql("SELECT count(*) FROM information_schema.tables WHERE table_schema='musica' AND table_name IN ('spotify_imports','spotify_import_tracks')") == '0'
    assert sql("SELECT count(*) FROM public.jobs WHERE kind='download_track' AND (payload ? 'import_id')") == '0'
    assert sql(f"SELECT count(*) FROM musica.tracks WHERE owner_id='{owner['user_id']}'") == '0'
    again = request('POST', '/api/spotify/import', {'library': [song]}, token=other['token'], expected=202)
    assert again['tracks'] == 1
    assert sql("SELECT count(*) FROM public.jobs WHERE kind='download_track'") == '2'
    request('GET', '/api/spotify/imports/00000000-0000-0000-0000-000000000000', token=token, expected=404)
    control = backend / '.zig-cache' / 'spotify-fixture-control.txt'
    control.write_text('hold')
    worker_env = dict(env, SPOTIFY_WORKER_ENABLED='true', HLS_WORKER_ENABLED='false', HTTP_PORT='0',
                      YTDLP_PATH=str(backend / 'zig-out' / 'bin' / ('yt-dlp-fixture.exe' if os.name == 'nt' else 'yt-dlp-fixture')),
                      SPOTIFY_FIXTURE_CONTROL=str(control), SPOTIFY_TMP_DIR=str(backend / '.zig-cache' / 'spotify-scratch'))
    # The secondary HTTP port is disposable; workers share only PostgreSQL and S3.
    import socket
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        worker_env['HTTP_PORT'] = str(listener.getsockname()[1])
    logfile = backend / '.zig-cache' / 'spotify-integration.log'

    def wait(predicate, seconds=20):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = status()
            if predicate(value):
                return value
            time.sleep(.1)
        raise AssertionError('Spotify job did not reach expected state: ' + json.dumps(value))

    with logfile.open('w', encoding='utf8') as log:
        worker = subprocess.Popen([str(executable)], cwd=backend, env=worker_env, stdout=log, stderr=log)
        try:
            processing = wait(lambda value: any(t['download'] == 'processing' for t in value['tracks']))
            track = next(t['id'] for t in processing['tracks'] if t['download'] == 'processing')
            attempt = sql(f"SELECT attempt_id::text FROM public.jobs WHERE kind='download_track' AND dedupe_key='{track}'")
            request('DELETE', '/api/tracks/' + track, token=token, expected=204)
            assert sql(f"SELECT count(*) FROM musica.tracks WHERE id='{track}'") == '1'
            request('PUT', f'/api/playlists/{default}/tracks/{track}', token=token, expected=204)
            request('PUT', '/api/tracks/' + track + '/file', b'audio', mime='audio/mpeg', token=token, expected=404)
            assert sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='musica' AND state='idle in transaction'") == '0'
            # The old worker finishes its child with an expired lease. Publication
            # must roll back; the next claim recovers using a new attempt UUID.
            sql(f"UPDATE public.jobs SET lease_until=clock_timestamp()-interval '1 second' WHERE kind='download_track' AND dedupe_key='{track}'")
            control.write_text('go')
            completed = wait(lambda value: all(t['download'] == 'completed' for t in value['tracks']))
            assert all(t['status'] == 'ready' and t['preparation'] == 'queued' for t in completed['tracks'])
            assert sql(f"SELECT attempt_id::text FROM public.jobs WHERE kind='download_track' AND dedupe_key='{track}'") != attempt
            assert sql(f"SELECT attempts FROM public.jobs WHERE kind='download_track' AND dedupe_key='{track}'") == '2'
            for t in completed['tracks']:
                assert sql(f"SELECT content_type || ':' || size_bytes FROM musica.tracks WHERE id='{t['id']}'") == 'audio/mpeg:33'
                assert sql(f"SELECT count(*) FROM public.jobs WHERE kind='upload_track' AND dedupe_key='{t['id']}' AND state='completed'") == '1'
            control.write_text('fail')
            failing = {'library': [{'title': 'Get Lucky (Live)', 'artist': 'Daft Punk'}]}
            request('POST', '/api/spotify/import', failing, token=token, expected=202)
            failed_id = sql("SELECT id::text FROM musica.tracks WHERE title='Get Lucky (Live)'")
            for attempt in range(1, 4):
                wait(lambda value: sql(f"SELECT state || ':' || attempts FROM public.jobs WHERE kind='download_track' AND dedupe_key='{failed_id}'") in (f'queued:{attempt}', f'failed:{attempt}'))
                if attempt < 3:
                    sql(f"UPDATE public.jobs SET available_at=clock_timestamp() WHERE kind='download_track' AND dedupe_key='{failed_id}'")
            assert sql(f"SELECT state FROM public.jobs WHERE kind='download_track' AND dedupe_key='{failed_id}'") == 'failed'
            control.write_text('go')
            request('POST', '/api/spotify/import', failing, token=token, expected=202)
            wait(lambda value: all(t['download'] == 'completed' for t in value['tracks']))
            assert not any((backend / '.zig-cache' / 'spotify-scratch').iterdir()), 'scratch directories must be removed'
            log.flush()
            assert 'LeaseLost' in logfile.read_text(encoding='utf8')
            print('PASS: Spotify import deduplication/ACL/default playlist, offline MP3 publication, stale worker fencing, HLS enqueue and retry.')
        finally:
            worker.terminate()
            worker.wait(timeout=10)
