const std = @import("std");
const database = @import("../database.zig");

/// Создаёт обычного пользователя с готовым хешем; триггер БД создаёт его Uploads.
/// Возвращает ID в arena, транзакцию оставляет вызывающему сервису.
pub fn create(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    username: []const u8,
    password_hash: []const u8,
) ![]const u8 {
    const query = "INSERT INTO musica.users(username, password_hash) VALUES ($1, $2) RETURNING id::text";

    return (try conn.queryText(arena, query, .{ username, password_hash })) orelse error.DatabaseUnavailable;
}

/// Создаёт сервисную учётку без пароля или возвращает ID существующей.
pub fn ensureSystem(conn: *database.Connection, arena: std.mem.Allocator) ![]const u8 {
    const query =
        \\INSERT INTO musica.users AS u(username, password_hash, kind)
        \\VALUES ('musica_service', NULL, 'system')
        \\ON CONFLICT (kind)
        \\WHERE kind = 'system'
        \\DO UPDATE
        \\SET kind = EXCLUDED.kind
        \\RETURNING u.id::text
    ;

    return (try conn.queryText(arena, query, .{})) orelse error.DatabaseUnavailable;
}

/// Проверяет роль администратора у обычного пользователя; иначе Forbidden.
pub fn requireAdmin(conn: *database.Connection, arena: std.mem.Allocator, user: []const u8) !void {
    const query = "SELECT id::text FROM musica.users WHERE id = $1 AND kind = 'user' AND role = 'admin'";

    _ = (try conn.queryText(arena, query, .{user})) orelse return error.Forbidden;
}

/// Создаёт первого администратора под транзакционной блокировкой; существующего не меняет.
pub fn bootstrapAdmin(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    username: []const u8,
    hash: []const u8,
) !void {
    const lock_query = "SELECT pg_advisory_xact_lock(761189302)::text";

    _ = try conn.queryText(arena, lock_query, .{});

    const existing_query = "SELECT id::text FROM musica.users WHERE role = 'admin'";

    if (try conn.queryText(arena, existing_query, .{}) != null) return;

    const create_query = "INSERT INTO musica.users(username, password_hash, role) VALUES ($1, $2, 'admin')";

    _ = try conn.exec(create_query, .{ username, hash });
}
