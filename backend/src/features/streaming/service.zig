const std = @import("std");
const App = @import("../../app.zig").App;
const model = @import("model.zig");
const database = @import("../../infrastructure/database.zig");
const repository = @import("repository.zig");
const jobs_repository = @import("../../infrastructure/jobs/repository.zig");

pub fn read(db: *database.Database, arena: std.mem.Allocator, id: []const u8, user: ?[]const u8, share_hash: ?[]const u8) !model.State {
    const conn = try db.acquire();
    defer conn.release();
    try conn.begin();
    errdefer conn.rollback() catch {};
    var result = try repository.read(conn, arena, id, user, share_hash);
    const key = try std.ascii.allocLowerString(arena, id);
    if (try jobs_repository.findByKey(conn, arena, model.preparation_job_kind, key)) |job| result.preparation = job.state;
    try conn.commit();
    return result;
}

pub fn enqueue(db: *database.Database, arena: std.mem.Allocator, id: []const u8, user: []const u8) !model.State {
    const conn = try db.acquire();
    defer conn.release();
    try conn.begin();
    errdefer conn.rollback() catch {};
    const input = try repository.lockForPreparation(conn, arena, id, user);
    if (input.status == .pending) return error.TrackNotUploaded;
    if (input.status == .ready) _ = try jobs_repository.enqueue(conn, arena, model.preparation_job_kind, input.payload.track_id, input.payload, 0, 3);
    var result = try repository.read(conn, arena, id, user, null);
    if (try jobs_repository.findByKey(conn, arena, model.preparation_job_kind, input.payload.track_id)) |job| result.preparation = job.state;
    try conn.commit();
    return result;
}

pub fn claim(db: *database.Database, arena: std.mem.Allocator) !?model.Task {
    const conn = try db.acquire();
    defer conn.release();
    const job = (try jobs_repository.claim(conn, arena, model.preparation_job_kind, 60)) orelse return null;
    const payload = job.decodePayload(model.Payload, arena) catch |err| {
        try jobs_repository.fail(conn, job, false, 0);
        return err;
    };
    return .{ .job = job, .payload = payload };
}

pub fn heartbeat(db: *database.Database, task: model.Task) !void {
    const conn = try db.acquire();
    defer conn.release();
    try jobs_repository.heartbeat(conn, task.job, 60);
}

pub fn finish(db: *database.Database, task: model.Task, prefix: []const u8, segments: u32) !void {
    const conn = try db.acquire();
    defer conn.release();
    try conn.begin();
    errdefer conn.rollback() catch {};
    try repository.finishPreparation(conn, task.payload.track_id, task.payload.bucket, prefix, segments);
    try jobs_repository.complete(conn, task.job);
    try conn.commit();
}

pub fn failed(db: *database.Database, task: model.Task, retry: bool) !void {
    const conn = try db.acquire();
    defer conn.release();
    jobs_repository.fail(conn, task.job, retry, 30) catch |err| if (err != error.LeaseLost) return err;
}

pub fn object(app: *App, arena: std.mem.Allocator, state: model.State, name: []const u8, max_bytes: usize) ![]const u8 {
    if (state.status != .streamed) return error.HlsNotReady;
    const bucket = state.bucket orelse return error.DatabaseUnavailable;
    const key = try std.fmt.allocPrint(arena, "{s}/{s}", .{ state.prefix orelse return error.DatabaseUnavailable, name });
    return app.storage.getInBucket(arena, bucket, key, max_bytes) catch |err| {
        std.log.err("HLS storage read failed: {s}", .{@errorName(err)});
        if (err == error.StorageTimeout) return error.StorageTimeout;
        return error.StorageUnavailable;
    };
}
