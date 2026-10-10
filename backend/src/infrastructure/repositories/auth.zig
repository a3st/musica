const std = @import("std");
const database = @import("../database.zig");
const Login = @import("../../features/auth/model.zig").Login;

/// Создаёт пользователя с готовым хешем пароля и возвращает его ID.
pub fn createUser(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    username: []const u8,
    password_hash: []const u8,
) ![]const u8 {
    const query = "INSERT INTO musica.users(username, password_hash) VALUES ($1, $2) RETURNING id::text";

    const id = (try conn.queryText(arena, query, .{ username, password_hash })) orelse return error.DatabaseUnavailable;
    return id;
}

/// Возвращает ID и хеш пароля обычного пользователя; null, если он не найден.
pub fn findCredentials(conn: *database.Connection, arena: std.mem.Allocator, username: []const u8) !?Login {
    const query =
        \\SELECT json_build_object('id', id, 'password_hash', password_hash)::text
        \\FROM musica.users
        \\WHERE username = $1
        \\AND kind = 'user'
    ;

    const body = (try conn.queryText(arena, query, .{username})) orelse return null;

    return std.json.parseFromSliceLeaky(Login, arena, body, .{}) catch error.DatabaseUnavailable;
}

/// Сохраняет сессию по хешу токена; срок действия задаётся схемой БД.
pub fn createSession(conn: *database.Connection, user_id: []const u8, hash: []const u8) !void {
    const query = "INSERT INTO musica.sessions(user_id, token_hash) VALUES ($1, $2)";

    _ = try conn.exec(query, .{ user_id, hash });
}

/// Возвращает ID пользователя действующей сессии; иначе Unauthorized.
pub fn resolveSession(conn: *database.Connection, arena: std.mem.Allocator, hash: []const u8) ![]const u8 {
    const query =
        \\SELECT s.user_id::text
        \\FROM musica.sessions s
        \\JOIN musica.users u
        \\ON u.id = s.user_id
        \\WHERE s.token_hash = $1
        \\AND s.expires_at > now()
        \\AND u.kind = 'user'
    ;

    return (try conn.queryText(arena, query, .{hash})) orelse error.Unauthorized;
}

/// Удаляет сессию по хешу токена; отсутствие сессии допустимо.
pub fn removeSession(conn: *database.Connection, hash: []const u8) !void {
    const query = "DELETE FROM musica.sessions WHERE token_hash = $1";

    _ = try conn.exec(query, .{hash});
}

/// Возвращает JSON профиля с ID дефолтного плейлиста; иначе NotFound.
pub fn readUser(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8) ![]const u8 {
    const query =
        \\SELECT json_build_object('id', u.id, 'username', u.username, 'default_playlist_id',
        \\    a.id)::text
        \\FROM musica.users u
        \\JOIN musica.playlists a
        \\ON a.owner_id = u.id
        \\AND a.is_default
        \\WHERE u.id = $1
    ;

    return (try conn.queryText(
        arena,
        query,
        .{id},
    )) orelse error.NotFound;
}
