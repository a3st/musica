const std = @import("std");
const database = @import("../database.zig");

/// Возвращает JSON собственного профиля с ролью и ID Uploads; иначе NotFound.
pub fn read(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8) ![]const u8 {
    const query =
        \\SELECT json_build_object('id', u.id, 'username', u.username, 'role', u.role, 'default_playlist_id',
        \\    a.id)::text
        \\FROM musica.users u
        \\JOIN musica.playlists a
        \\ON a.owner_id = u.id
        \\AND a.is_default
        \\WHERE u.id = $1
    ;

    return (try conn.queryText(arena, query, .{id})) orelse error.NotFound;
}

/// Возвращает хеш пароля обычного пользователя в arena.
pub fn readCredentials(conn: *database.Connection, arena: std.mem.Allocator, user: []const u8) ![]const u8 {
    return (try conn.queryText(arena, "SELECT password_hash FROM musica.users WHERE id = $1 AND kind = 'user'", .{user})) orelse error.Unauthorized;
}

/// Блокирует обычную учётку до завершения транзакции и возвращает актуальный хеш.
pub fn lockCredentials(conn: *database.Connection, arena: std.mem.Allocator, user: []const u8) ![]const u8 {
    return (try conn.queryText(arena, "SELECT password_hash FROM musica.users WHERE id = $1 AND kind = 'user' FOR UPDATE", .{user})) orelse error.Unauthorized;
}

/// Возвращает ID личных треков в стабильном порядке для удаления через tracks operations.
pub fn listOwnedTracks(conn: *database.Connection, arena: std.mem.Allocator, user: []const u8) ![]const []const u8 {
    const body = (try conn.queryText(
        arena,
        "SELECT COALESCE(json_agg(id::text ORDER BY id), '[]'::json)::text FROM musica.tracks WHERE owner_id = $1",
        .{user},
    )) orelse return error.DatabaseUnavailable;

    return std.json.parseFromSliceLeaky([]const []const u8, arena, body, .{}) catch error.DatabaseUnavailable;
}

/// Возвращает ключи обложек плейлистов; блокирует плейлисты от одновременного обновления.
pub fn listPlaylistImages(conn: *database.Connection, arena: std.mem.Allocator, user: []const u8) ![]const []const u8 {
    const query =
        \\SELECT COALESCE(json_agg(image_key) FILTER (WHERE image_key IS NOT NULL), '[]'::json)::text
        \\FROM (SELECT image_key FROM musica.playlists WHERE owner_id = $1 ORDER BY id FOR UPDATE) p
    ;
    const body = (try conn.queryText(arena, query, .{user})) orelse return error.DatabaseUnavailable;

    return std.json.parseFromSliceLeaky([]const []const u8, arena, body, .{}) catch error.DatabaseUnavailable;
}

/// Меняет хеш пароля и отзывает все сессии; требует транзакции вызывающего сервиса.
pub fn setPassword(conn: *database.Connection, user: []const u8, hash: []const u8) !void {
    _ = try conn.exec("UPDATE musica.users SET password_hash = $2 WHERE id = $1", .{ user, hash });
    _ = try conn.exec("DELETE FROM musica.sessions WHERE user_id = $1", .{user});
}

/// Удаляет привязки, плейлисты и пользователя после удаления личных треков.
/// Сервисные треки сохраняются; триггер пересчитывает их orphaned_at.
pub fn remove(conn: *database.Connection, user: []const u8) !void {
    _ = try conn.exec("DELETE FROM musica.track_playlists WHERE playlist_id IN (SELECT id FROM musica.playlists WHERE owner_id = $1)", .{user});
    _ = try conn.exec("DELETE FROM musica.playlists WHERE owner_id = $1", .{user});
    _ = try conn.exec("DELETE FROM musica.users WHERE id = $1 AND kind = 'user'", .{user});
}
