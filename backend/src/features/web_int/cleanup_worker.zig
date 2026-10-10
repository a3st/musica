const std = @import("std");
const App = @import("../../app.zig").App;
const model = @import("model.zig");
const repository = @import("repository.zig");
const jobs_repository = @import("../../infrastructure/jobs/repository.zig");
const tracks_operations = @import("../tracks/operations.zig");

pub fn run(app: *App) anyerror!void {
    while (true) {
        var arena = std.heap.ArenaAllocator.init(app.storage.allocator);
        defer arena.deinit();
        cycle(app, arena.allocator()) catch |err| {
            if (err == error.Canceled) return err;
            std.log.err("Unused shared track cleanup failed: {s}", .{@errorName(err)});
        };
        try std.Io.sleep(app.storage.io, .fromSeconds(30), .awake);
    }
}

pub fn cycle(app: *App, arena: std.mem.Allocator) !void {
    const conn = try app.db.acquire();
    defer conn.release();
    for (try repository.listCleanupCandidates(conn, arena, app.shared_track_retention_seconds)) |id| {
        _ = try jobs_repository.enqueue(conn, arena, model.cleanup_job_kind, id, .{ .track_id = id }, 0, null);
    }
    const job = (try jobs_repository.claim(conn, arena, model.cleanup_job_kind, 60)) orelse return;
    const payload = try job.decodePayload(struct { track_id: []const u8 }, arena);
    try conn.begin();
    errdefer conn.rollback() catch {};
    if (try repository.lockForCleanup(conn, arena, payload.track_id, app.shared_track_retention_seconds)) |owner| {
        tracks_operations.remove(conn, arena, owner, payload.track_id) catch |err| {
            try conn.rollback();
            try jobs_repository.fail(conn, job, true, 30);
            return err;
        };
    }
    try jobs_repository.removeLeased(conn, job);
    try conn.commit();
}
