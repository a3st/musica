const std = @import("std");
const database = @import("../database.zig");
const tracks_model = @import("../../features/tracks/model.zig");

/// Предполагаемый S3-путь для нового трека; n — строка с его UUID в запросе создания.
pub const source_key_sql = "'tracks/' || n.id::text || '/source'";

/// Ищет до 25 загруженных пользовательских треков в доступных плейлистах без дублей.
/// Возвращает один доступный playlist_id на трек; поиск не раскрывает приватные плейлисты.
pub fn searchLibrary(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    user: []const u8,
    words: []const u8,
) ![]const tracks_model.LibraryMatch {
    const query =
        \\SELECT COALESCE(json_agg(result.item), '[]'::json)::text
        \\FROM (
        \\    SELECT json_build_object(
        \\        'track', json_build_object('id', t.id, 'title', t.title, 'artist', t.artist,
        \\            'owner_id', t.owner_id, 'status', t.status, 'owner_kind', u.kind,
        \\            'duration_seconds', t.duration_seconds, 'artwork_key', t.artwork_key),
        \\        'playlist_id', accessible.id) AS item
        \\    FROM musica.tracks t JOIN musica.users u ON u.id = t.owner_id
        \\    JOIN LATERAL (
        \\        SELECT p.id FROM musica.track_playlists tp
        \\        JOIN musica.playlists p ON p.id = tp.playlist_id
        \\        WHERE tp.track_id = t.id AND p.owner_id IS NOT NULL
        \\        AND (p.visibility = 'public' OR p.owner_id = $1::uuid
        \\            OR EXISTS (SELECT 1 FROM musica.playlist_members m
        \\                WHERE m.playlist_id = p.id AND m.user_id = $1::uuid))
        \\        ORDER BY (p.owner_id = $1::uuid) DESC, p.id
        \\        LIMIT 1
        \\    ) accessible ON true
        \\    WHERE u.kind = 'user' AND t.status IN ('ready', 'streamed')
        \\    AND NOT EXISTS (
        \\        SELECT 1 FROM jsonb_array_elements_text($2::jsonb) AS words(word)
        \\        WHERE strpos(lower(t.title || ' ' || t.artist), lower(words.word)) = 0)
        \\    ORDER BY lower(t.title), lower(t.artist), t.id
        \\    LIMIT 25
        \\) result
    ;
    const body = (try conn.queryText(arena, query, .{ user, words })) orelse return error.DatabaseUnavailable;

    return std.json.parseFromSliceLeaky([]const tracks_model.LibraryMatch, arena, body, .{}) catch error.DatabaseUnavailable;
}

/// Создаёт личный pending-трек с предполагаемым S3-путём; возвращает ID без привязки к плейлистам.
pub fn create(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    user: []const u8,
    bucket: []const u8,
    input: tracks_model.CreateTrack,
) ![36]u8 {
    const create_query =
        \\WITH new_track AS (
        \\    SELECT gen_random_uuid() AS id) INSERT INTO musica.tracks(id, title, artist, owner_id,
        \\    storage_bucket, object_key)
        \\SELECT n.id, $1, $2, $3, $4,
    ++ source_key_sql ++
        \\ FROM new_track n
        \\RETURNING id::text
    ;

    const id = (try conn.queryText(
        arena,
        create_query,
        .{ input.title, input.artist, user, bucket },
    )) orelse return error.DatabaseUnavailable;
    if (!tracks_model.isValidId(id)) return error.DatabaseUnavailable;
    return id[0..36].*;
}

/// Блокирует строку трека и возвращает ID и тип владельца; иначе TrackNotFound.
pub fn lockOwner(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8) !tracks_model.Owner {
    const query =
        \\SELECT json_build_object('id', u.id, 'kind', u.kind)::text
        \\FROM musica.tracks t
        \\JOIN musica.users u
        \\ON u.id = t.owner_id
        \\WHERE t.id = $1
        \\FOR UPDATE OF t
    ;

    const body = (try conn.queryText(arena, query, .{id})) orelse return error.TrackNotFound;

    return std.json.parseFromSliceLeaky(tracks_model.Owner, arena, body, .{});
}

/// Блокирует трек владельца без ожидания и возвращает расположение исходника и HLS.
/// Занятая строка приводит к UploadInProgress; отсутствие трека — к TrackNotFound.
pub fn lockForDeletion(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    user: []const u8,
    id: []const u8,
) !tracks_model.Files {
    const query =
        \\SELECT json_build_object('bucket', storage_bucket, 'key', object_key, 'prefix', hls_prefix,
        \\    'hls_bucket', hls_bucket, 'segments', hls_segment_count, 'artwork_key', artwork_key)::text
        \\FROM musica.tracks
        \\WHERE id = $1
        \\AND owner_id = $2
        \\FOR UPDATE NOWAIT
    ;

    const body = (conn.queryText(arena, query, .{ id, user }) catch |err| {
        if (err == error.LockUnavailable) return error.UploadInProgress;
        return err;
    }) orelse return error.TrackNotFound;

    return std.json.parseFromSliceLeaky(tracks_model.Files, arena, body, .{}) catch error.DatabaseUnavailable;
}

/// Удаляет запись трека и каскадные связи; объекты в S3 удаляет отдельная задача.
pub fn remove(conn: *database.Connection, id: []const u8) !void {
    const query = "DELETE FROM musica.tracks WHERE id = $1";

    _ = try conn.exec(query, .{id});
}

/// Блокирует pending-трек владельца без ожидания и возвращает S3-путь.
/// Занятая строка приводит к UploadInProgress, уже загруженный трек — к AlreadyUploaded.
pub fn lockForUpload(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    id: []const u8,
    user: []const u8,
) !tracks_model.UploadLocation {
    const query =
        \\SELECT json_build_object('bucket', storage_bucket, 'key', object_key, 'status', status)::text
        \\FROM musica.tracks
        \\WHERE id = $1
        \\AND owner_id = $2
        \\FOR UPDATE NOWAIT
    ;

    const body = (conn.queryText(arena, query, .{ id, user }) catch |err| {
        if (err == error.LockUnavailable) return error.UploadInProgress;
        return err;
    }) orelse return error.TrackNotFound;

    const state = std.json.parseFromSliceLeaky(struct {
        bucket: []const u8,
        key: []const u8,
        status: tracks_model.Status,
    }, arena, body, .{}) catch return error.DatabaseUnavailable;

    if (state.status != .pending) return error.AlreadyUploaded;
    return .{ .bucket = state.bucket, .key = state.key };
}

/// Сохраняет ключ и метаданные загруженного файла, переводя pending-трек в ready.
pub fn finishUpload(conn: *database.Connection, id: []const u8, key: []const u8, mime: []const u8, size: usize) !void {
    const query =
        \\UPDATE musica.tracks
        \\SET status = 'ready', object_key = $2, content_type = $3, size_bytes = $4, uploaded_at = now()
        \\WHERE id = $1
        \\AND status = 'pending'
    ;

    if (try conn.exec(query, .{ id, key, mime, @as(i64, @intCast(size)) }) != 1) return error.UploadInProgress;
}

/// Блокирует строку трека до конца транзакции; иначе TrackNotFound.
pub fn lock(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8) !void {
    const query = "SELECT id::text FROM musica.tracks WHERE id = $1 FOR UPDATE";

    _ = (try conn.queryText(arena, query, .{id})) orelse return error.TrackNotFound;
}

/// Публикует метаданные только для того исходника, который обрабатывала задача.
pub fn setMetadata(
    conn: *database.Connection,
    payload: tracks_model.MetadataPayload,
    metadata: tracks_model.Metadata,
) !void {
    const query =
        \\UPDATE musica.tracks
        \\SET duration_seconds = $4, artwork_key = $5
        \\WHERE id = $1 AND storage_bucket = $2 AND object_key = $3
        \\AND status IN ('ready', 'streamed')
    ;

    if (try conn.exec(query, .{
        payload.track_id,
        payload.bucket,
        payload.key,
        metadata.duration_seconds,
        metadata.artwork_key,
    }) != 1)
        return error.TrackNotFound;
}

/// Возвращает расположение обложки после проверки владения, членства, публичности или ссылки.
/// Отсутствие обложки и отсутствие доступа одинаково возвращают NotFound.
pub fn readArtwork(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    id: []const u8,
    user: ?[]const u8,
    share_hash: ?[]const u8,
) !tracks_model.UploadLocation {
    const query =
        \\SELECT json_build_object('bucket', t.storage_bucket, 'key', t.artwork_key)::text
        \\FROM musica.tracks t
        \\WHERE t.id = $1 AND t.owner_id IS NOT NULL AND t.artwork_key IS NOT NULL
        \\AND (t.owner_id = $2::uuid
        \\    OR ($2::uuid IS NOT NULL AND EXISTS (
        \\        SELECT 1 FROM musica.users u WHERE u.id = t.owner_id AND u.kind = 'system'))
        \\    OR EXISTS (
        \\    SELECT 1 FROM musica.track_playlists tp
        \\    JOIN musica.playlists p ON p.id = tp.playlist_id
        \\    WHERE tp.track_id = t.id AND p.owner_id IS NOT NULL
        \\    AND (p.visibility = 'public' OR p.owner_id = $2::uuid
        \\        OR EXISTS (SELECT 1 FROM musica.playlist_members m
        \\            WHERE m.playlist_id = p.id AND m.user_id = $2::uuid)
        \\        OR (p.visibility = 'unlisted' AND p.share_token_hash = $3))))
    ;

    const body = (try conn.queryText(arena, query, .{ id, user, share_hash })) orelse return error.NotFound;

    return std.json.parseFromSliceLeaky(tracks_model.UploadLocation, arena, body, .{}) catch error.DatabaseUnavailable;
}
