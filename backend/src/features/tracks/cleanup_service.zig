const std = @import("std");
const database = @import("../../infrastructure/database.zig");
const model = @import("model.zig");
const jobs_repository = @import("../../infrastructure/jobs/repository.zig");

pub fn enqueue(conn: *database.Connection, arena: std.mem.Allocator, bucket: []const u8, keys: []const []const u8, delay: u32) ![]const u8 {
    const task = try jobs_repository.insert(conn, arena, model.cleanup_job_kind, model.CleanupPayload{ .bucket = bucket, .keys = keys }, delay, null);
    return task.id;
}

pub fn reserve(conn: *database.Connection, arena: std.mem.Allocator, bucket: []const u8, key: []const u8) ![]const u8 {
    return enqueue(conn, arena, bucket, &.{key}, 120);
}

pub fn publish(conn: *database.Connection, id: []const u8) !void {
    jobs_repository.cancelScheduled(conn, id) catch |err| {
        if (err == error.LeaseLost) return error.UploadInProgress;
        return err;
    };
}

pub fn claim(db: *database.Database, arena: std.mem.Allocator) !?model.CleanupTask {
    const conn = try db.acquire();
    defer conn.release();
    const job = (try jobs_repository.claim(conn, arena, model.cleanup_job_kind, 120)) orelse return null;
    const payload = job.decodePayload(model.CleanupPayload, arena) catch |err| {
        try jobs_repository.fail(conn, job, false, 0);
        return err;
    };
    return .{ .job = job, .payload = payload };
}

pub fn retry(db: *database.Database, task: model.CleanupTask) !void {
    const conn = try db.acquire();
    defer conn.release();
    try jobs_repository.fail(conn, task.job, true, 30);
}

pub fn finish(db: *database.Database, task: model.CleanupTask) !void {
    const conn = try db.acquire();
    defer conn.release();
    try jobs_repository.deleteOwned(conn, task.job);
}

pub fn heartbeat(db: *database.Database, task: model.CleanupTask) !void {
    const conn = try db.acquire();
    defer conn.release();
    try jobs_repository.heartbeat(conn, task.job, 120);
}
