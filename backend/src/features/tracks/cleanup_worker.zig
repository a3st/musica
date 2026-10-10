const std = @import("std");
const App = @import("../../app.zig").App;
const service = @import("cleanup_service.zig");
const Task = @import("model.zig").CleanupTask;

/// Обрабатывает очередь удаления S3-объектов до отмены; между циклами ждёт одну секунду.
pub fn run(app: *App) anyerror!void {
    const io = app.storage.io;

    while (true) {
        var arena = std.heap.ArenaAllocator.init(app.storage.allocator);
        defer arena.deinit();

        processNextTask(app, arena.allocator()) catch |err| {
            if (err == error.Canceled) return err;
            std.log.err("Track cleanup failed: {s}", .{@errorName(err)});
        };

        try std.Io.sleep(io, .fromSeconds(1), .awake);
    }
}

/// Арендует одну задачу очистки и удаляет объекты параллельно с продлением аренды.
/// Дожидается остановки параллельной работы перед повтором или завершением задачи.
fn processNextTask(app: *App, arena: std.mem.Allocator) !void {
    const task = (try service.claim(&app.db, arena)) orelse return;
    std.log.info(
        "S3 cleanup claimed job {s}, attempt {s}: {d} objects",
        .{ task.job.id, task.job.attempt_id.?, task.payload.keys.len },
    );

    const Result = union(enum) {
        output: anyerror!void,
        lease: anyerror!void,
    };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(app.storage.io, &buffer);
    defer select.cancelDiscard();

    try select.concurrent(.output, deleteObjects, .{ app, task });
    try select.concurrent(.lease, maintainLease, .{ app, task });

    const result = switch (try select.await()) {
        .output => |value| value,
        .lease => |value| value,
    };
    // Join canceled work before returning its task to the queue.
    select.cancelDiscard();

    result catch |err| {
        if (err == error.Canceled) return err;
        std.log.err("S3 cleanup job {s} failed: {s}", .{ task.job.id, @errorName(err) });
        try service.retry(&app.db, task);

        return err;
    };

    service.finish(&app.db, task) catch |err| {
        std.log.err("S3 cleanup job {s} completion failed: {s}", .{ task.job.id, @errorName(err) });

        return err;
    };
    std.log.info("S3 cleanup completed job {s}", .{task.job.id});
}

/// Удаляет ключи задачи из указанного бакета; временная память освобождается после каждого объекта.
fn deleteObjects(app: *App, task: Task) anyerror!void {
    for (task.payload.keys, 0..) |key, index| {
        var arena = std.heap.ArenaAllocator.init(app.storage.allocator);
        defer arena.deinit();

        try app.storage.deleteInBucket(arena.allocator(), task.payload.bucket, key);
        std.log.debug("S3 cleanup job {s}: deleted object {d}/{d}", .{ task.job.id, index + 1, task.payload.keys.len });
    }
}

/// Продлевает аренду задачи каждые 15 секунд до отмены или ошибки.
fn maintainLease(app: *App, task: Task) anyerror!void {
    while (true) {
        try std.Io.sleep(app.storage.io, .fromSeconds(15), .awake);
        try service.heartbeat(&app.db, task);
    }
}
