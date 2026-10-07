const std = @import("std");
const pg = @import("pg");
const sql = @import("../../helpers/sql.zig");

const json_playlist =
    \\json_build_object('id', a.id, 'owner_id', a.owner_id, 'title', a.title,
    \\'description', a.description, 'tags', a.tags, 'visibility', a.visibility,
    \\'is_default', a.is_default, 'image_key', a.image_key,
    \\'tracks', COALESCE((SELECT json_agg(json_build_object('id', t.id, 'title', t.title,
    \\'artist', t.artist, 'status', t.status, 'owner_id', t.owner_id) ORDER BY t.created_at, t.id)
    \\FROM tracks t JOIN track_playlists ta ON ta.track_id = t.id WHERE ta.playlist_id = a.id), '[]'::json))::text
;

pub fn list(pool: *pg.Pool, arena: std.mem.Allocator, user: []const u8) ![]const u8 {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    return (try sql.text(conn, arena, "SELECT COALESCE(json_agg(item ORDER BY is_default DESC, title, id), '[]'::json)::text FROM (SELECT a.id,a.title,a.is_default,json_build_object('id',a.id,'owner_id',a.owner_id,'title',a.title,'description',a.description,'visibility',a.visibility,'is_default',a.is_default,'image_key',a.image_key,'role',CASE WHEN a.owner_id=$1 THEN 'owner' ELSE m.role END,'track_count',(SELECT count(*) FROM track_playlists tp WHERE tp.playlist_id=a.id)) AS item FROM playlists a LEFT JOIN playlist_members m ON m.playlist_id=a.id AND m.user_id=$1 WHERE a.owner_id=$1 OR m.user_id=$1) accessible", .{user})) orelse error.DatabaseUnavailable;
}

pub fn create(pool: *pg.Pool, arena: std.mem.Allocator, user: []const u8, title: []const u8, description: []const u8, tags: []const u8, visibility: []const u8) ![]const u8 {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    return (try sql.text(
        conn,
        arena,
        "INSERT INTO playlists (owner_id, title, description, tags, visibility) VALUES ($1, $2, $3, $4::jsonb, $5) RETURNING id::text",
        .{ user, title, description, tags, visibility },
    )) orelse error.DatabaseUnavailable;
}

pub fn read(pool: *pg.Pool, arena: std.mem.Allocator, id: []const u8, user: ?[]const u8) ![]const u8 {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    return (try sql.text(
        conn,
        arena,
        "SELECT " ++ json_playlist ++ " FROM playlists a WHERE a.id = $1 AND a.owner_id IS NOT NULL AND (a.visibility = 'public' OR a.owner_id = $2::uuid OR EXISTS (SELECT 1 FROM playlist_members m WHERE m.playlist_id = a.id AND m.user_id = $2::uuid))",
        .{ id, user },
    )) orelse error.NotFound;
}

pub fn readShared(pool: *pg.Pool, arena: std.mem.Allocator, hash: []const u8) ![]const u8 {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    return (try sql.text(
        conn,
        arena,
        "SELECT " ++ json_playlist ++ " FROM playlists a WHERE a.visibility = 'unlisted' AND a.share_token_hash = $1 AND a.owner_id IS NOT NULL",
        .{hash},
    )) orelse error.NotFound;
}

pub fn requireWrite(conn: *pg.Conn, arena: std.mem.Allocator, id: []const u8, user: []const u8, owner_only: bool) !void {
    _ = (try sql.text(
        conn,
        arena,
        "SELECT a.id::text FROM playlists a WHERE a.id = $1 AND (a.owner_id = $2 OR (NOT $3 AND EXISTS (SELECT 1 FROM playlist_members m WHERE m.playlist_id = a.id AND m.user_id = $2 AND m.role = 'editor'))) FOR UPDATE OF a",
        .{ id, user, owner_only },
    )) orelse return error.NotFound;
}

pub fn update(pool: *pg.Pool, arena: std.mem.Allocator, id: []const u8, user: []const u8, title: []const u8, description: []const u8, tags: []const u8, visibility: []const u8) !void {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    conn.begin() catch return error.DatabaseUnavailable;
    errdefer conn.rollback() catch {};
    try requireWrite(conn, arena, id, user, false);
    _ = try sql.exec(
        conn,
        "UPDATE playlists SET title = $2, description = $3, tags = $4::jsonb, visibility = $5, share_token_hash = CASE WHEN $5 = 'unlisted' THEN share_token_hash ELSE NULL END WHERE id = $1",
        .{ id, title, description, tags, visibility },
    );
    conn.commit() catch return error.DatabaseUnavailable;
}

pub fn membership(pool: *pg.Pool, arena: std.mem.Allocator, id: []const u8, owner: []const u8, user: []const u8, role: ?[]const u8) !void {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    conn.begin() catch return error.DatabaseUnavailable;
    errdefer conn.rollback() catch {};
    try requireWrite(conn, arena, id, owner, true);
    if (std.ascii.eqlIgnoreCase(owner, user)) return error.InvalidInput;
    if (role) |value| {
        _ = try sql.exec(conn, "INSERT INTO playlist_members (playlist_id, user_id, role) VALUES ($1, $2, $3) ON CONFLICT (playlist_id, user_id) DO UPDATE SET role = EXCLUDED.role", .{ id, user, value });
    } else {
        _ = try sql.exec(conn, "DELETE FROM playlist_members WHERE playlist_id = $1 AND user_id = $2", .{ id, user });
    }
    conn.commit() catch return error.DatabaseUnavailable;
}

pub fn link(pool: *pg.Pool, arena: std.mem.Allocator, id: []const u8, user: []const u8, hash: ?[]const u8) !void {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    conn.begin() catch return error.DatabaseUnavailable;
    errdefer conn.rollback() catch {};
    try requireWrite(conn, arena, id, user, true);
    if (try sql.exec(conn, "UPDATE playlists SET share_token_hash = $2 WHERE id = $1 AND visibility = 'unlisted' AND NOT is_default", .{ id, hash }) != 1) return error.InvalidInput;
    conn.commit() catch return error.DatabaseUnavailable;
}

pub fn track(pool: *pg.Pool, arena: std.mem.Allocator, id: []const u8, user: []const u8, track_id: []const u8, add: bool) !void {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    conn.begin() catch return error.DatabaseUnavailable;
    errdefer conn.rollback() catch {};
    try requireWrite(conn, arena, id, user, false);
    if (add) {
        // Adding someone else's track would expose its metadata without their consent.
        _ = (try sql.text(conn, arena, "SELECT id::text FROM tracks WHERE id = $1 AND owner_id = $2 FOR UPDATE", .{ track_id, user })) orelse return error.TrackNotFound;
        _ = try sql.exec(conn, "INSERT INTO track_playlists (playlist_id, track_id) VALUES ($1, $2) ON CONFLICT DO NOTHING", .{ id, track_id });
    } else {
        if ((try sql.text(conn, arena, "SELECT id::text FROM playlists WHERE id = $1 AND is_default", .{id})) != null) {
            _ = (try sql.text(conn, arena, "SELECT track_id::text FROM track_playlists WHERE playlist_id=$1 AND track_id=$2", .{ id, track_id })) orelse return error.TrackNotFound;
            try @import("../tracks/repository.zig").removeWithConn(conn, arena, user, track_id);
        } else if (try sql.exec(conn, "DELETE FROM track_playlists WHERE playlist_id = $1 AND track_id = $2", .{ id, track_id }) != 1) return error.TrackNotFound;
    }
    conn.commit() catch return error.DatabaseUnavailable;
}

pub const ImageUpload = struct {
    conn: *pg.Conn,
    committed: bool = false,

    pub fn begin(pool: *pg.Pool, arena: std.mem.Allocator, id: []const u8, user: []const u8) !ImageUpload {
        const conn = pool.acquire() catch return error.DatabaseUnavailable;
        errdefer conn.release();
        conn.begin() catch return error.DatabaseUnavailable;
        errdefer conn.rollback() catch {};
        try requireWrite(conn, arena, id, user, false);
        return .{ .conn = conn };
    }

    pub fn finish(self: *ImageUpload, id: []const u8, key: []const u8) !void {
        _ = try sql.exec(self.conn, "UPDATE playlists SET image_key = $2 WHERE id = $1", .{ id, key });
        self.conn.commit() catch return error.DatabaseUnavailable;
        self.committed = true;
    }

    pub fn deinit(self: *ImageUpload) void {
        if (!self.committed) self.conn.rollback() catch {};
        self.conn.release();
    }
};
