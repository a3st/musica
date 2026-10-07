const std = @import("std");
const pg = @import("pg");
const model = @import("model.zig");
const sql = @import("../../helpers/sql.zig");
const playlists = @import("../playlists/repository.zig");

pub fn create(pool: *pg.Pool, arena: std.mem.Allocator, user: []const u8, bucket: []const u8, input: model.CreateTrack) ![36]u8 {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    conn.begin() catch return error.DatabaseUnavailable;
    errdefer conn.rollback() catch {};
    const id = (try sql.text(
        conn,
        arena,
        "WITH new_track AS (SELECT gen_random_uuid() AS id) INSERT INTO tracks (id, title, artist, owner_id, storage_bucket, object_key) SELECT id, $1, $2, $3, $4, 'tracks/' || id::text || '/source' FROM new_track RETURNING id::text",
        .{ input.title, input.artist, user, bucket },
    )) orelse return error.DatabaseUnavailable;
    if (!model.validId(id)) return error.DatabaseUnavailable;
    const result = id[0..36].*;
    if (try sql.exec(conn, "INSERT INTO track_playlists (track_id, playlist_id) SELECT $1, id FROM playlists WHERE owner_id = $2 AND is_default", .{ &result, user }) != 1)
        return error.DatabaseUnavailable;
    for (input.playlist_ids) |playlist_id| {
        try playlists.requireWrite(conn, arena, playlist_id, user, false);
        _ = sql.exec(
            conn,
            "INSERT INTO track_playlists (track_id, playlist_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
            .{ &result, playlist_id },
        ) catch |err| {
            if (err == error.ReferenceNotFound) return error.PlaylistNotFound;
            return err;
        };
    }
    conn.commit() catch return error.DatabaseUnavailable;
    return result;
}

pub const Upload = struct {
    conn: *pg.Conn,
    bucket: []const u8,
    key: []const u8,
    committed: bool = false,

    pub fn begin(pool: *pg.Pool, arena: std.mem.Allocator, id: []const u8, user: []const u8) !Upload {
        const conn = pool.acquire() catch return error.DatabaseUnavailable;
        errdefer conn.release();
        conn.begin() catch return error.DatabaseUnavailable;
        errdefer conn.rollback() catch {};

        // NOWAIT rejects simultaneous writes instead of letting them overwrite the object.
        const state_json = (sql.text(
            conn,
            arena,
            "SELECT json_build_object('status', status, 'bucket', storage_bucket, 'key', object_key)::text FROM tracks WHERE id = $1 AND owner_id = $2 FOR UPDATE NOWAIT",
            .{ id, user },
        ) catch |err| {
            if (err == error.LockUnavailable) return error.UploadInProgress;
            return err;
        }) orelse return error.TrackNotFound;
        const state = std.json.parseFromSliceLeaky(struct { status: model.TrackStatus, bucket: []const u8, key: []const u8 }, arena, state_json, .{}) catch return error.DatabaseUnavailable;
        if (state.status != .pending) return error.AlreadyUploaded;
        return .{ .conn = conn, .bucket = state.bucket, .key = state.key };
    }

    pub fn finish(self: *Upload, id: []const u8, mime: []const u8, size: usize) !void {
        const affected = try sql.exec(
            self.conn,
            "UPDATE tracks SET status = 'ready', content_type = $2, size_bytes = $3, uploaded_at = now() WHERE id = $1 AND status = 'pending'",
            .{ id, mime, @as(i64, @intCast(size)) },
        );
        if (affected != 1) return error.DatabaseUnavailable;
        self.conn.commit() catch return error.DatabaseUnavailable;
        self.committed = true;
    }

    pub fn deinit(self: *Upload) void {
        if (!self.committed) self.conn.rollback() catch {};
        self.conn.release();
    }
};

pub fn remove(pool: *pg.Pool, arena: std.mem.Allocator, user: []const u8, id: []const u8) !void {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    conn.begin() catch return error.DatabaseUnavailable;
    errdefer conn.rollback() catch {};
    try removeWithConn(conn, arena, user, id);
    conn.commit() catch return error.DatabaseUnavailable;
}

pub fn removeWithConn(conn: *pg.Conn, arena: std.mem.Allocator, user: []const u8, id: []const u8) !void {
    const body = (sql.text(conn, arena, "SELECT json_build_object('bucket',storage_bucket,'key',object_key,'prefix',hls_prefix,'hls_bucket',hls_bucket,'segments',hls_segment_count)::text FROM tracks WHERE id=$1 AND owner_id=$2 FOR UPDATE NOWAIT", .{ id, user }) catch |err| {
        if (err == error.LockUnavailable) return error.UploadInProgress;
        return err;
    }) orelse return error.TrackNotFound;
    const job = sql.text(conn, arena, "SELECT (state='processing' AND lease_until>now())::text FROM track_hls_jobs WHERE track_id=$1 FOR UPDATE NOWAIT", .{id}) catch |err| {
        if (err == error.LockUnavailable) return error.TrackPreparationInProgress;
        return err;
    };
    if (job) |state| if (std.mem.eql(u8, state, "true")) return error.TrackPreparationInProgress;
    const location = try std.json.parseFromSliceLeaky(struct { bucket: []const u8, key: []const u8, prefix: ?[]const u8, hls_bucket: ?[]const u8, segments: ?u32 }, arena, body, .{});
    const source_keys = try std.json.Stringify.valueAlloc(arena, [_][]const u8{location.key}, .{});
    _ = try sql.exec(conn, "INSERT INTO track_file_deletions (bucket,object_keys) VALUES ($1,$2::jsonb)", .{ location.bucket, source_keys });
    if (location.prefix) |prefix| {
        var keys: std.ArrayList([]const u8) = .empty;
        for (0..location.segments.?) |index| try keys.append(arena, try std.fmt.allocPrint(arena, "{s}/segment-{d:0>6}.ts", .{ prefix, index }));
        try keys.append(arena, try std.fmt.allocPrint(arena, "{s}/index.m3u8", .{prefix}));
        const encoded = try std.json.Stringify.valueAlloc(arena, keys.items, .{});
        _ = try sql.exec(conn, "INSERT INTO track_file_deletions (bucket,object_keys) VALUES ($1,$2::jsonb)", .{ location.hls_bucket.?, encoded });
    }
    _ = try sql.exec(conn, "DELETE FROM tracks WHERE id=$1", .{id});
}
