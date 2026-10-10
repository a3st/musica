const std = @import("std");
const database = @import("../database.zig");
const tracks_model = @import("../../features/tracks/model.zig");

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

/// Создаёт pending-трек с предполагаемым S3-путём и привязывает к Uploads; возвращает ID.
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
        \\SELECT id, $1, $2, $3, $4, 'tracks/' || id::text || '/source'
        \\FROM new_track
        \\RETURNING id::text
    ;

    const id = (try conn.queryText(
        arena,
        create_query,
        .{ input.title, input.artist, user, bucket },
    )) orelse return error.DatabaseUnavailable;
    if (!tracks_model.isValidId(id)) return error.DatabaseUnavailable;
    const result = id[0..36].*;

    const link_query =
        \\INSERT INTO musica.track_playlists(track_id, playlist_id)
        \\SELECT $1, id
        \\FROM musica.playlists
        \\WHERE owner_id = $2
        \\AND is_default
    ;

    if (try conn.exec(link_query, .{ &result, user }) != 1)
        return error.DatabaseUnavailable;
    return result;
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
        \\    'hls_bucket', hls_bucket, 'segments', hls_segment_count)::text
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
