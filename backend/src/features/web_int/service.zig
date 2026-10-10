const std = @import("std");
const App = @import("../../app.zig").App;
const database = @import("../../infrastructure/database.zig");
const model = @import("model.zig");
const repository = @import("repository.zig");
const jobs_repository = @import("../../infrastructure/jobs/repository.zig");
const tracks_model = @import("../tracks/model.zig");
const playlists_repository = @import("../playlists/repository.zig");
const users_repository = @import("../users/repository.zig");

pub fn create(conn: *database.Connection, arena: std.mem.Allocator, bucket: []const u8, user: []const u8, track: model.Track, source: ?model.Source) ![]const u8 {
    _ = try tracks_model.validateCreate(.{ .title = track.title, .artist = track.artist });
    const owner = try users_repository.ensureSystem(conn, arena);
    // Keep lock order consistent: user/playlist first, then shared track and jobs.
    const target = try playlists_repository.lockDefault(conn, arena, user);
    const id = try repository.getOrCreateTrack(conn, arena, bucket, track, source);
    _ = try jobs_repository.enqueue(conn, arena, model.download_job_kind, id, model.Payload{ .user_id = owner, .track_id = id, .track = track }, 0, 3);
    try playlists_repository.addTrack(conn, arena, target, user, id);
    return id;
}

pub fn claim(db: *database.Database, arena: std.mem.Allocator) !?model.Task {
    const conn = try db.acquire();
    defer conn.release();
    const job = (try jobs_repository.claim(conn, arena, model.download_job_kind, 120)) orelse return null;
    const payload = job.decodePayload(model.Payload, arena) catch |err| {
        try jobs_repository.fail(conn, job, false, 0);
        return err;
    };
    return .{ .job = job, .payload = payload };
}

pub fn heartbeat(db: *database.Database, task: model.Task) !void {
    const conn = try db.acquire();
    defer conn.release();
    try jobs_repository.heartbeat(conn, task.job, 120);
}

pub fn finish(db: *database.Database, task: model.Task) !void {
    const conn = try db.acquire();
    defer conn.release();
    try jobs_repository.complete(conn, task.job);
}

pub fn failed(db: *database.Database, task: model.Task, retryable: bool) !void {
    const conn = try db.acquire();
    defer conn.release();
    jobs_repository.fail(conn, task.job, retryable, 30) catch |err| if (err != error.LeaseLost) return err;
}
