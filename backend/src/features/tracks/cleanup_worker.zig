const std = @import("std");
const App = @import("../../app.zig").App;
const service = @import("cleanup_service.zig");
const Job = @import("model.zig").CleanupTask;

pub fn run(app: *App) anyerror!void {
    const io = app.storage.io;
    while (true) {
        var arena = std.heap.ArenaAllocator.init(app.storage.allocator);
        defer arena.deinit();
        cycle(app, arena.allocator()) catch |err| {
            if (err == error.Canceled) return err;
            std.log.err("Track cleanup failed: {s}", .{@errorName(err)});
        };
        try std.Io.sleep(io, .fromSeconds(1), .awake);
    }
}

fn cycle(app: *App, arena: std.mem.Allocator) !void {
    const task = (try service.claim(&app.db, arena)) orelse return;
    const Result = union(enum) { output: anyerror!void, lease: anyerror!void };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(app.storage.io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.output, deleteFiles, .{ app, task });
    try select.concurrent(.lease, renew, .{ app, task });
    const result = switch (try select.await()) {
        .output => |value| value,
        .lease => |value| value,
    };
    // Join canceled work before returning its task to the queue.
    select.cancelDiscard();
    result catch |err| {
        if (err == error.Canceled) return err;
        try service.retry(&app.db, task);
        return err;
    };
    try service.finish(&app.db, task);
}

fn deleteFiles(app: *App, task: Job) anyerror!void {
    for (task.payload.keys) |key| {
        var arena = std.heap.ArenaAllocator.init(app.storage.allocator);
        defer arena.deinit();
        try app.storage.deleteInBucket(arena.allocator(), task.payload.bucket, key);
    }
}

fn renew(app: *App, task: Job) anyerror!void {
    while (true) {
        try std.Io.sleep(app.storage.io, .fromSeconds(15), .awake);
        try service.heartbeat(&app.db, task);
    }
}
