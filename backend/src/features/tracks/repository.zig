const std = @import("std");
const pg = @import("pg");
const model = @import("model.zig");

pub fn create(pool: *pg.Pool, input: model.CreateTrack) ![36]u8 {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    var row = (conn.rowOpts(
        "INSERT INTO tracks (album_id, title, artist) VALUES ($1, $2, $3) RETURNING id::text",
        .{ input.album_id, input.title, input.artist },
        .{ .timeout = 10000 },
    ) catch |err| {
        if (err == error.PG) {
            if (conn.err) |failure| {
                if (std.mem.eql(u8, failure.code, "23503")) return error.AlbumNotFound;
            }
        }
        return error.DatabaseUnavailable;
    }) orelse return error.DatabaseUnavailable;
    var row_finished = false;
    defer if (!row_finished) row.deinit() catch {};
    const id = row.get([]const u8, 0) catch return error.DatabaseUnavailable;
    if (!model.validId(id)) return error.DatabaseUnavailable;
    const result = id[0..36].*;
    row_finished = true;
    row.deinit() catch return error.DatabaseUnavailable;
    return result;
}

pub const Upload = struct {
    conn: *pg.Conn,
    committed: bool = false,

    pub fn begin(pool: *pg.Pool, id: []const u8) !Upload {
        const conn = pool.acquire() catch return error.DatabaseUnavailable;
        errdefer conn.release();
        conn.begin() catch return error.DatabaseUnavailable;
        errdefer conn.rollback() catch {};

        // NOWAIT rejects simultaneous writes instead of letting them overwrite the object.
        var row = (conn.rowOpts(
            "SELECT status FROM tracks WHERE id = $1 FOR UPDATE NOWAIT",
            .{id},
            .{ .timeout = 10000 },
        ) catch |err| {
            if (err == error.PG) {
                if (conn.err) |failure| {
                    if (std.mem.eql(u8, failure.code, "55P03")) return error.UploadInProgress;
                }
            }
            return error.DatabaseUnavailable;
        }) orelse return error.TrackNotFound;
        var row_finished = false;
        defer if (!row_finished) row.deinit() catch {};
        const status = row.get([]const u8, 0) catch return error.DatabaseUnavailable;
        const pending = std.mem.eql(u8, status, "pending");
        row_finished = true;
        row.deinit() catch return error.DatabaseUnavailable;
        if (!pending) return error.AlreadyUploaded;
        return .{ .conn = conn };
    }

    pub fn finish(self: *Upload, id: []const u8, bucket: []const u8, key: []const u8, mime: []const u8, size: usize) !void {
        const affected = self.conn.execOpts(
            "UPDATE tracks SET status = 'ready', storage_bucket = $2, object_key = $3, content_type = $4, size_bytes = $5, uploaded_at = now() WHERE id = $1 AND status = 'pending'",
            .{ id, bucket, key, mime, @as(i64, @intCast(size)) },
            .{ .timeout = 10000 },
        ) catch return error.DatabaseUnavailable;
        if (affected != 1) return error.DatabaseUnavailable;
        self.conn.commit() catch return error.DatabaseUnavailable;
        self.committed = true;
    }

    pub fn deinit(self: *Upload) void {
        if (!self.committed) self.conn.rollback() catch {};
        self.conn.release();
    }
};
