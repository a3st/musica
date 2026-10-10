const std = @import("std");
const database = @import("../database.zig");
const tracks_model = @import("../../features/tracks/model.zig");
const imports_model = @import("../../features/imports/model.zig");
const tracks_repository = @import("tracks.zig");

/// Возвращает статус трека указанного владельца; иначе TrackNotFound.
pub fn readTrackStatus(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    user: []const u8,
    id: []const u8,
) !tracks_model.Status {
    const query = "SELECT status::text FROM musica.tracks WHERE id = $1 AND owner_id = $2";

    const value = (try conn.queryText(arena, query, .{ id, user })) orelse return error.TrackNotFound;
    return std.meta.stringToEnum(tracks_model.Status, value) orelse error.DatabaseUnavailable;
}

/// Возвращает существующий общий трек или создаёт его у сервисной учётки.
/// Дедупликация по источнику и полному названию выполняется с блокировками в транзакции.
/// Для непривязанного трека обновляет начало срока хранения при повторном выборе.
pub fn getOrCreateSharedTrack(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    owner: []const u8,
    bucket: []const u8,
    track: imports_model.Track,
    source: ?imports_model.Source,
) ![]const u8 {
    // Serialize source aliases too: two nodes can supply different names for the same ID.
    if (source) |s| {
        const source_lock_query = "SELECT pg_advisory_xact_lock(hashtextextended($1 || ':' || $2, 0))::text";

        _ = try conn.queryText(arena, source_lock_query, .{ s.provider, s.external_id });

        const source_query =
            \\SELECT t.id::text
            \\FROM musica.track_sources s
            \\JOIN musica.tracks t
            \\ON t.id = s.track_id
            \\WHERE s.provider = $1
            \\AND s.external_id = $2
            \\AND t.owner_id = $3
            \\FOR UPDATE OF t
        ;

        if (try conn.queryText(arena, source_query, .{ s.provider, s.external_id, owner })) |id| {
            _ = try conn.exec("UPDATE musica.tracks SET orphaned_at = clock_timestamp() WHERE id = $1 AND orphaned_at IS NOT NULL", .{id});
            return id;
        }
    }

    const track_query =
        \\WITH n AS (
        \\    SELECT gen_random_uuid() id
        \\)
        \\INSERT INTO musica.tracks AS t(
        \\    id, title, artist, owner_id, storage_bucket, object_key, catalog_key, orphaned_at
        \\)
        \\SELECT n.id, $1, $2, u.id, $3,
    ++ tracks_repository.source_key_sql ++
        \\, musica.track_identity($2, $1), clock_timestamp()
        \\FROM n, musica.users u
        \\WHERE u.id = $4 AND u.kind = 'system'
        \\ON CONFLICT (catalog_key)
        \\DO UPDATE
        \\SET catalog_key = EXCLUDED.catalog_key,
        \\    orphaned_at = CASE WHEN t.orphaned_at IS NULL THEN NULL ELSE clock_timestamp() END
        \\RETURNING t.id::text
    ;

    const id = (try conn.queryText(arena, track_query, .{ track.title, track.artist, bucket, owner })) orelse return error.DatabaseUnavailable;

    const link_query =
        \\INSERT INTO musica.track_sources(provider, external_id, track_id)
        \\VALUES ($1, $2, $3)
        \\ON CONFLICT
        \\DO NOTHING
    ;

    if (source) |s| _ = try conn.exec(link_query, .{ s.provider, s.external_id, id });
    return id;
}
