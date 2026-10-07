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
        "WITH new_track AS (SELECT gen_random_uuid() AS id) INSERT INTO tracks (id, title, artist, owner_id, storage_bucket, object_key) SELECT id, $1, $2, $3, $4, 'tracks/' || id::text FROM new_track RETURNING id::text",
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
        const state = std.json.parseFromSliceLeaky(struct { status: []const u8, bucket: []const u8, key: []const u8 }, arena, state_json, .{}) catch return error.DatabaseUnavailable;
        if (!std.mem.eql(u8, state.status, "pending")) return error.AlreadyUploaded;
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
