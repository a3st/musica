"""Проверки профиля и админки, запускаемые только в одноразовой БД API-тестов."""

import json
import uuid

from support import wait_for


def check_profile_and_admin(api_request, execute_sql):
    """Проверяет ACL, отзыв сессий, откат удаления и очередь очистки личных файлов."""
    password = "profile-fixture-password-123"
    new_password = "changed-fixture-password-456"
    admin = api_request("POST", "/api/auth/register", {
        "username": "profile_admin", "password": password,
    }, expected=201)
    token = admin["token"]
    admin_id = admin["user_id"]
    api_request("GET", "/api/admin/storage", token=token, expected=403)
    api_request("GET", "/api/admin/users", token=token, expected=403)
    api_request("POST", "/api/admin/storage/cleanup-orphaned", token=token, expected=403)
    api_request("GET", "/api/admin/users", expected=401)
    execute_sql(f"UPDATE musica.users SET role='admin' WHERE id='{admin_id}'")
    assert api_request("GET", "/api/users/me", token=token)["role"] == "admin"

    account = api_request("POST", "/api/admin/users", {
        "username": "profile_target", "password": password,
    }, token=token, expected=201)["id"]
    users = api_request("GET", "/api/admin/users", token=token)
    assert any(user["id"] == account for user in users)
    assert all("password_hash" not in user and user["username"] != "musica_service" for user in users)
    login = api_request("POST", "/api/auth/login", {
        "username": "profile_target", "password": password,
    })["token"]
    api_request("DELETE", f"/api/admin/users/{admin_id}", token=token, expected=403)
    api_request("DELETE", f"/api/admin/users/{account}", token=login, expected=403)

    track = api_request("POST", "/api/tracks", {
        "title": "Deletion fixture", "artist": "Test",
    }, token=login, expected=201)["id"]
    attempt = str(uuid.uuid4())
    job_id = execute_sql(f"""
        INSERT INTO public.jobs(kind, dedupe_key, state, attempt_id, lease_until, payload)
        VALUES ('upload_track', '{track}', 'processing', '{attempt}',
            clock_timestamp() + interval '60 seconds', '{{}}') RETURNING id;
    """)
    api_request("DELETE", "/api/profile", {"password": password}, token=login, expected=409)
    assert execute_sql(f"SELECT count(*) FROM musica.users WHERE id='{account}'") == "1"
    assert execute_sql(f"SELECT count(*) FROM musica.tracks WHERE id='{track}'") == "1"
    execute_sql(f"DELETE FROM public.jobs WHERE id='{job_id}'")
    api_request("PUT", "/api/tracks/" + track + "/file", b"fixture-audio", token=login,
                mime="audio/mpeg", expected=200)
    location = json.loads(execute_sql(f"SELECT json_build_object('bucket', storage_bucket, 'key', object_key) FROM musica.tracks WHERE id='{track}'"))

    api_request("PUT", "/api/profile/password", {
        "password": "wrong-password-123", "new_password": new_password,
    }, token=login, expected=401)
    api_request("PUT", "/api/profile/password", {
        "password": password, "new_password": new_password,
    }, token=login, expected=204)
    api_request("GET", "/api/users/me", token=login, expected=401)
    api_request("POST", "/api/auth/login", {
        "username": "profile_target", "password": password,
    }, expected=401)
    login = api_request("POST", "/api/auth/login", {
        "username": "profile_target", "password": new_password,
    })["token"]
    api_request("DELETE", "/api/profile", {"password": new_password}, token=login, expected=204)
    api_request("GET", "/api/users/me", token=login, expected=401)
    assert execute_sql(f"SELECT count(*) FROM musica.users WHERE id='{account}'") == "0"
    assert execute_sql(f"SELECT count(*) FROM musica.playlists WHERE owner_id='{account}'") == "0"
    assert execute_sql(f"SELECT count(*) FROM musica.tracks WHERE id='{track}'") == "0"
    wait_for(
        lambda: execute_sql(f"SELECT count(*) FROM public.jobs WHERE kind='delete_s3_objects' AND payload->>'bucket'='{location['bucket']}' AND payload->'keys' ? '{location['key']}' AND state='completed'"),
        lambda count: int(count) > 0,
        timeout_seconds=20,
        description="account source cleanup",
    )

    second = api_request("POST", "/api/admin/users", {
        "username": "admin_deleted_target", "password": password,
    }, token=token, expected=201)["id"]
    api_request("DELETE", f"/api/admin/users/{second}", token=token, expected=204)
    assert execute_sql(f"SELECT count(*) FROM musica.users WHERE id='{second}'") == "0"
    stats = api_request("GET", "/api/admin/storage", token=token)
    assert stats["source_bytes"] == stats["user_bytes"] + stats["system_bytes"]
    assert stats["orphaned_bytes"] <= stats["system_bytes"]

    # A terminal download must not count as waiting, unlike a queued upload.
    failed_track = api_request("POST", "/api/tracks", {
        "title": "Failed import counter", "artist": "Test",
    }, token=token, expected=201)["id"]
    before = api_request("GET", "/api/admin/storage", token=token)["pending_tracks"]
    execute_sql(f"""
        INSERT INTO public.jobs(kind, dedupe_key, state, payload)
        VALUES ('download_track', '{failed_track}', 'failed', '{{}}');
    """)
    assert api_request("GET", "/api/admin/storage", token=token)["pending_tracks"] == before - 1
    execute_sql(f"UPDATE public.jobs SET state='queued' WHERE kind='download_track' AND dedupe_key='{failed_track}'")
    assert api_request("GET", "/api/admin/storage", token=token)["pending_tracks"] == before

    # Manual cleanup must exceed the background worker's 20-track batch.
    system = execute_sql("SELECT id FROM musica.users WHERE kind='system' LIMIT 1")
    if not system:
        system = execute_sql("INSERT INTO musica.users(username, kind) VALUES ('cleanup_system_fixture', 'system') RETURNING id")
    fixtures = [str(uuid.uuid4()) for _ in range(23)]
    for fixture in fixtures:
        execute_sql(f"""
            INSERT INTO musica.tracks(id, owner_id, title, artist, storage_bucket, object_key, catalog_key, orphaned_at)
            VALUES ('{fixture}', '{system}', 'Cleanup fixture', 'Test', 'uploads',
                'fixture/{fixture}', 'fixture:{fixture}', clock_timestamp() - interval '1 hour');
        """)
    result = api_request("POST", "/api/admin/storage/cleanup-orphaned", token=token)
    assert result["removed"] >= len(fixtures), result
    identifiers = ",".join(f"'{fixture}'" for fixture in fixtures)
    assert execute_sql(f"SELECT count(*) FROM musica.tracks WHERE id IN ({identifiers})") == "0"
    print("PASS: profile password change, session revocation, account deletion rollback, admin ACL and source cleanup.")
