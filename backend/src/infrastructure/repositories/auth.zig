const std = @import("std");
const database = @import("../database.zig");
const Login = @import("../../features/auth/model.zig").Login;

pub fn register(conn: *database.Connection, arena: std.mem.Allocator, username: []const u8, password_hash: []const u8) ![]const u8 {
    const id = (try conn.text(arena, "INSERT INTO musica.users (username, password_hash) VALUES ($1, $2) RETURNING id::text", .{ username, password_hash })) orelse return error.DatabaseUnavailable;
    return id;
}

pub fn credentials(conn: *database.Connection, arena: std.mem.Allocator, username: []const u8) !?Login {
    const body = (try conn.text(arena, "SELECT json_build_object('id',id,'password_hash',password_hash)::text FROM musica.users WHERE username=$1", .{username})) orelse return null;
    return std.json.parseFromSliceLeaky(Login, arena, body, .{}) catch error.DatabaseUnavailable;
}

pub fn session(conn: *database.Connection, user_id: []const u8, hash: []const u8) !void {
    _ = try conn.exec("INSERT INTO musica.sessions (user_id, token_hash) VALUES ($1, $2)", .{ user_id, hash });
}

pub fn resolve(conn: *database.Connection, arena: std.mem.Allocator, hash: []const u8) ![]const u8 {
    return (try conn.text(arena, "SELECT user_id::text FROM musica.sessions WHERE token_hash = $1 AND expires_at > now()", .{hash})) orelse error.Unauthorized;
}

pub fn logout(conn: *database.Connection, hash: []const u8) !void {
    _ = try conn.exec("DELETE FROM musica.sessions WHERE token_hash = $1", .{hash});
}

pub fn me(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8) ![]const u8 {
    return (try conn.text(
        arena,
        "SELECT json_build_object('id', u.id, 'username', u.username, 'default_playlist_id', a.id)::text FROM musica.users u JOIN musica.playlists a ON a.owner_id = u.id AND a.is_default WHERE u.id = $1",
        .{id},
    )) orelse error.NotFound;
}
