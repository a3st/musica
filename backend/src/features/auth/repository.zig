const std = @import("std");
const pg = @import("pg");
const sql = @import("../../helpers/sql.zig");

pub fn register(pool: *pg.Pool, arena: std.mem.Allocator, username: []const u8, password_hash: []const u8, token_hash: []const u8) ![]const u8 {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    conn.begin() catch return error.DatabaseUnavailable;
    errdefer conn.rollback() catch {};
    const id = (try sql.text(conn, arena, "INSERT INTO users (username, password_hash) VALUES ($1, $2) RETURNING id::text", .{ username, password_hash })) orelse return error.DatabaseUnavailable;
    _ = try sql.exec(conn, "INSERT INTO sessions (token_hash, user_id) VALUES ($1, $2)", .{ token_hash, id });
    conn.commit() catch return error.DatabaseUnavailable;
    return id;
}

pub const Login = struct { id: []const u8, password_hash: []const u8 };

pub fn credentials(pool: *pg.Pool, arena: std.mem.Allocator, username: []const u8) !?Login {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    var row = (conn.rowOpts("SELECT id::text, password_hash FROM users WHERE username = $1", .{username}, .{ .timeout = 10000 }) catch return error.DatabaseUnavailable) orelse return null;
    defer row.deinit() catch {};
    return .{
        .id = try arena.dupe(u8, row.get([]const u8, 0) catch return error.DatabaseUnavailable),
        .password_hash = try arena.dupe(u8, row.get([]const u8, 1) catch return error.DatabaseUnavailable),
    };
}

pub fn session(pool: *pg.Pool, user_id: []const u8, hash: []const u8) !void {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    _ = try sql.exec(conn, "INSERT INTO sessions (user_id, token_hash) VALUES ($1, $2)", .{ user_id, hash });
}

pub fn resolve(pool: *pg.Pool, arena: std.mem.Allocator, hash: []const u8) ![]const u8 {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    return (try sql.text(conn, arena, "SELECT user_id::text FROM sessions WHERE token_hash = $1 AND expires_at > now()", .{hash})) orelse error.Unauthorized;
}

pub fn logout(pool: *pg.Pool, hash: []const u8) !void {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    _ = try sql.exec(conn, "DELETE FROM sessions WHERE token_hash = $1", .{hash});
}

pub fn me(pool: *pg.Pool, arena: std.mem.Allocator, id: []const u8) ![]const u8 {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    return (try sql.text(
        conn,
        arena,
        "SELECT json_build_object('id', u.id, 'username', u.username, 'default_playlist_id', a.id)::text FROM users u JOIN playlists a ON a.owner_id = u.id AND a.is_default WHERE u.id = $1",
        .{id},
    )) orelse error.NotFound;
}
