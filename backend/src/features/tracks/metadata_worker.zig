const std = @import("std");
const builtin = @import("builtin");
const App = @import("../../app.zig").App;
const auth_model = @import("../auth/model.zig");
const model = @import("model.zig");
const service = @import("metadata_service.zig");

/// Обрабатывает очередь длительности и обложек до отмены, независимо от HLS.
pub fn run(app: *App) anyerror!void {
    const io = app.storage.io;

    while (true) {
        var arena = std.heap.ArenaAllocator.init(app.storage.allocator);
        defer arena.deinit();

        const task = service.claim(&app.db, arena.allocator()) catch |err| {
            if (err == error.Canceled) return err;
            std.log.err("Track metadata queue unavailable: {s}", .{@errorName(err)});
            try std.Io.sleep(io, .fromSeconds(5), .awake);
            continue;
        };

        if (task) |value| {
            processTask(app, arena.allocator(), value) catch |err| {
                if (err == error.Canceled) return err;
                std.log.err("Track metadata failed for {s}: {s}", .{ value.payload.track_id, @errorName(err) });
                const retry = err != error.InvalidMedia and err != error.InvalidInput and
                    err != error.FileNotFound and err != error.TrackNotFound;
                service.fail(&app.db, value, retry) catch |failure|
                    std.log.err("Track metadata failure update failed: {s}", .{@errorName(failure)});
            };
        } else {
            try std.Io.sleep(io, .fromSeconds(1), .awake);
        }
    }
}

/// Продлевает аренду параллельно с обработкой и ограничивает общее время задачи.
fn processTask(app: *App, arena: std.mem.Allocator, task: model.MetadataTask) !void {
    const Result = union(enum) {
        output: anyerror!void,
        heartbeat: anyerror!void,
        timeout: anyerror!void,
    };
    var buffer: [3]Result = undefined;
    var select = std.Io.Select(Result).init(app.storage.io, &buffer);
    defer select.cancelDiscard();

    try select.concurrent(.output, inspectAndPublish, .{ app, arena, task });
    try select.concurrent(.heartbeat, maintainLease, .{ app, task });
    try select.concurrent(.timeout, waitForTimeout, .{ app.storage.io, app.metadata_timeout_seconds });

    switch (try select.await()) {
        .output => |result| try result,
        .heartbeat => |result| {
            try result;
            return error.LeaseLost;
        },
        .timeout => |result| {
            try result;
            return error.MetadataTimeout;
        },
    }
}

/// Продлевает аренду каждые 15 секунд до остановки обработки.
fn maintainLease(app: *App, task: model.MetadataTask) anyerror!void {
    while (true) {
        try std.Io.sleep(app.storage.io, .fromSeconds(15), .awake);
        try service.heartbeat(&app.db, task);
    }
}

/// Ожидает общий таймаут обработки метаданных.
fn waitForTimeout(io: std.Io, seconds: u32) anyerror!void {
    try std.Io.sleep(io, .fromSeconds(seconds), .awake);
}

/// Скачивает исходник, читает длительность и публикует нормализованную обложку; временные файлы удаляет при отмене.
fn inspectAndPublish(app: *App, arena: std.mem.Allocator, task: model.MetadataTask) anyerror!void {
    if (!model.isValidId(task.payload.track_id) or !model.isValidId(task.job.attempt_id.?) or
        task.payload.size == 0 or task.payload.size > app.max_upload_bytes) return error.InvalidInput;

    const io = app.storage.io;
    var root = try std.Io.Dir.cwd().createDirPathOpen(io, app.metadata_tmp_dir, .{});
    defer root.close(io);
    const permissions: std.Io.Dir.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
    try root.createDir(io, task.job.attempt_id.?, permissions);
    defer {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        root.deleteTree(io, task.job.attempt_id.?) catch |err|
            std.log.warn("Track metadata scratch cleanup failed: {s}", .{@errorName(err)});
    }

    var dir = try root.openDir(io, task.job.attempt_id.?, .{});
    defer dir.close(io);
    {
        var download = std.heap.ArenaAllocator.init(app.storage.allocator);
        defer download.deinit();
        const source = try app.storage.getInBucket(download.allocator(), task.payload.bucket, task.payload.key, task.payload.size);
        if (source.len != task.payload.size) return error.InvalidMedia;
        try dir.writeFile(io, .{ .sub_path = "source", .data = source });
    }

    const probe = try app.probe.inspect(
        arena,
        io,
        dir,
        "source",
    );

    var metadata: model.Metadata = .{ .duration_seconds = probe.duration_seconds, .artwork_key = null };
    var reservation: ?[]const u8 = null;

    if (probe.artwork_stream) |index| {
        // A damaged embedded picture must not prevent publication of the audio duration.
        app.ffmpeg.extractArtwork(arena, io, dir, "source", index, "artwork.jpg") catch |err| {
            if (err == error.Canceled) return err;
            std.log.warn("Embedded artwork extraction failed for {s}: {s}", .{ task.payload.track_id, @errorName(err) });
            try service.publish(app, arena, task, metadata, null);
            return;
        };

        const image = try dir.readFileAlloc(io, "artwork.jpg", arena, .limited(model.max_artwork_bytes));
        if (image.len == 0) return error.InvalidMedia;
        const token = try auth_model.generateToken(io);
        const key = try std.fmt.allocPrint(arena, "tracks/{s}/artwork/{s}-{s}-{s}-{s}-{s}.jpg", .{
            task.payload.track_id, token[0..8], token[8..12], token[12..16], token[16..20], token[20..32],
        });
        reservation = try service.reserveArtwork(app, arena, task, key);
        try app.storage.putInBucket(arena, task.payload.bucket, key, "image/jpeg", image);
        metadata.artwork_key = key;
    }

    try service.publish(app, arena, task, metadata, reservation);
    std.log.info("Track metadata published: {s}", .{task.payload.track_id});
}
