const std = @import("std");
const database = @import("../database.zig");
const admin_model = @import("../../features/admin/model.zig");

/// Возвращает обычные аккаунты без хешей паролей и токенов; системная учётка исключена.
pub fn listUsers(conn: *database.Connection, arena: std.mem.Allocator) ![]const u8 {
    const query =
        \\SELECT COALESCE(json_agg(row_to_json(result)), '[]'::json)::text
        \\FROM (
        \\    SELECT u.id::text, u.username, u.role, u.created_at::text,
        \\        (SELECT count(*) FROM musica.tracks t WHERE t.owner_id = u.id) AS tracks
        \\    FROM musica.users u WHERE u.kind = 'user'
        \\    ORDER BY u.created_at, u.id
        \\) result
    ;
    return (try conn.queryText(arena, query, .{})) orelse error.DatabaseUnavailable;
}

/// Возвращает согласованный снимок размеров исходников из БД, без сетевого обращения к S3.
/// Orphaned учитывает только сервисные треки без привязок к пользовательским плейлистам.
pub fn readStorage(conn: *database.Connection, arena: std.mem.Allocator) !admin_model.Storage {
    const query =
        \\WITH files AS (
        \\    SELECT t.*, u.kind, u.kind = 'system' AND t.orphaned_at IS NOT NULL
        \\        AND NOT EXISTS (
        \\            SELECT 1 FROM musica.track_playlists tp
        \\            JOIN musica.playlists p ON p.id = tp.playlist_id
        \\            JOIN musica.users owner ON owner.id = p.owner_id
        \\            WHERE tp.track_id = t.id AND owner.kind = 'user'
        \\        ) AS orphaned
        \\    FROM musica.tracks t JOIN musica.users u ON u.id = t.owner_id
        \\)
        \\SELECT json_build_object(
        \\    'source_bytes', COALESCE(sum(size_bytes), 0),
        \\    'user_bytes', COALESCE(sum(size_bytes) FILTER (WHERE kind = 'user'), 0),
        \\    'system_bytes', COALESCE(sum(size_bytes) FILTER (WHERE kind = 'system'), 0),
        \\    'orphaned_bytes', COALESCE(sum(size_bytes) FILTER (WHERE orphaned), 0),
        \\    'tracks', count(*),
        \\    'orphaned_tracks', count(*) FILTER (WHERE orphaned),
        \\    'pending_tracks', count(*) FILTER (WHERE status = 'pending'),
        \\    'hls_segments', COALESCE(sum(hls_segment_count), 0),
        \\    'cleanup_jobs', (SELECT count(*) FROM public.jobs
        \\        WHERE kind = 'delete_s3_objects' AND state IN ('queued', 'processing'))
        \\)::text FROM files
    ;
    const body = (try conn.queryText(arena, query, .{})) orelse return error.DatabaseUnavailable;

    return std.json.parseFromSliceLeaky(admin_model.Storage, arena, body, .{}) catch error.DatabaseUnavailable;
}
