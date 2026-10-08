const std = @import("std");
const App = @import("../../app.zig").App;
const model = @import("model.zig");
const repository = @import("repository.zig");
const operations = @import("operations.zig");
const playlists_repository = @import("../playlists/repository.zig");
const cleanup_service = @import("cleanup_service.zig");
const jobs_repository = @import("../../infrastructure/jobs/repository.zig");
const Job = @import("../../infrastructure/jobs/model.zig").Job;
const auth_model = @import("../auth/model.zig");

pub fn create(app: *App, arena: std.mem.Allocator, user: []const u8, raw: model.CreateTrack) ![36]u8 {
    const input = try model.validateCreate(raw);
    const conn = try app.db.acquire();
    defer conn.release();
    try conn.begin();
    errdefer conn.rollback() catch {};
    const id = try repository.create(conn, arena, user, app.storage.bucket, input);
    for (input.playlist_ids) |playlist_id| {
        try playlists_repository.requireWrite(conn, arena, playlist_id, user, false);
        try playlists_repository.addTrack(conn, arena, playlist_id, user, &id);
    }
    try conn.commit();
    return id;
}

pub const StorageLocation = model.UploadLocation;

pub fn remove(app: *App, arena: std.mem.Allocator, user: []const u8, id: []const u8) !void {
    const conn = try app.db.acquire();
    defer conn.release();
    try conn.begin();
    errdefer conn.rollback() catch {};
    try operations.remove(conn, arena, user, id);
    try conn.commit();
}

pub fn upload(app: *App, arena: std.mem.Allocator, user: []const u8, id: []const u8, mime: []const u8, data: []const u8) !StorageLocation {
    const token = try auth_model.newToken(app.storage.io);
    // A random UUID identifies the upload owner across nodes.
    const attempt = try std.fmt.allocPrint(arena, "{s}-{s}-{s}-{s}-{s}", .{ token[0..8], token[8..12], token[12..16], token[16..20], token[20..32] });
    var reservation: []const u8 = undefined;
    var lease: Job = undefined;
    const canonical_id = try std.ascii.allocLowerString(arena, id);
    const location = blk: {
        const conn = try app.db.acquire();
        defer conn.release();
        try conn.begin();
        errdefer conn.rollback() catch {};
        const original = try repository.lockForUpload(conn, arena, canonical_id, user);
        const value: model.UploadLocation = .{ .bucket = original.bucket, .key = try std.fmt.allocPrint(arena, "{s}/attempts/{s}", .{ original.key, attempt }) };
        lease = jobs_repository.acquire(conn, arena, model.upload_job_kind, canonical_id, attempt, model.UploadPayload{ .track_id = canonical_id, .bucket = value.bucket, .key = value.key }, 120) catch |err| {
            if (err == error.LeaseLost) return error.UploadInProgress;
            return err;
        };
        reservation = try cleanup_service.reserve(conn, arena, value.bucket, value.key);
        try conn.commit();
        break :blk value;
    };
    // Release ownership on failure; cleanup remains durable and each retry has a distinct key.
    errdefer {
        const protection = app.storage.io.swapCancelProtection(.blocked);
        defer _ = app.storage.io.swapCancelProtection(protection);
        releaseUpload(app, lease) catch |err| std.log.err("Upload release failed: {s}", .{@errorName(err)});
    }
    app.storage.putInBucket(arena, location.bucket, location.key, mime, data) catch |err| {
        std.log.err("Track storage upload failed: {s}", .{@errorName(err)});
        if (err == error.Canceled) return err;
        if (err == error.StorageTimeout) return error.StorageTimeout;
        return error.StorageUnavailable;
    };
    {
        const conn = try app.db.acquire();
        defer conn.release();
        try conn.begin();
        errdefer conn.rollback() catch {};
        try repository.lock(conn, arena, canonical_id);
        jobs_repository.complete(conn, lease) catch |err| {
            if (err == error.LeaseLost) return error.UploadInProgress;
            return err;
        };
        try repository.finishUpload(conn, canonical_id, location.key, mime, data.len);
        try cleanup_service.publish(conn, reservation);
        try conn.commit();
    }
    return location;
}

fn releaseUpload(app: *App, lease: Job) !void {
    const conn = try app.db.acquire();
    defer conn.release();
    jobs_repository.fail(conn, lease, false, 0) catch |err| if (err != error.LeaseLost) return err;
}
