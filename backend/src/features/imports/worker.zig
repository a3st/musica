const std = @import("std");
const builtin = @import("builtin");
const App = @import("../../app.zig").App;
const model = @import("model.zig");
const service = @import("service.zig");
const repository = @import("repository.zig");
const tracks_model = @import("../tracks/model.zig");
const tracks_service = @import("../tracks/service.zig");
const streaming_service = @import("../streaming/service.zig");

/// Обрабатывает очередь скачивания до отмены; при отсутствии работы ждёт секунду, при ошибке очереди — пять.
/// Ошибки задачи фиксирует через сервис с выбором допустимости повтора.
pub fn run(app: *App) anyerror!void {
    if (!app.importsEnabled()) return;

    const io = app.storage.io;

    while (true) {
        var arena = std.heap.ArenaAllocator.init(app.storage.allocator);
        defer arena.deinit();

        const task = service.claim(&app.db, arena.allocator()) catch |err| {
            if (err == error.Canceled) return err;
            std.log.err("Import queue unavailable: {s}", .{@errorName(err)});

            try std.Io.sleep(io, .fromSeconds(5), .awake);
            continue;
        };

        if (task) |value| {
            processTask(app, arena.allocator(), value) catch |err| {
                if (err == error.Canceled) return err;
                std.log.err("Import download failed for {s}, attempt {s}: {s}", .{ value.payload.track_id, value.job.attempt_id.?, @errorName(err) });
                const retryable = err != error.FileNotFound and
                    err != error.InvalidInput and
                    err != error.InvalidText and
                    err != error.TrackNotFound and
                    err != error.FileTooLarge;
                service.fail(&app.db, value, retryable) catch |failure| std.log.err("Import job failure update failed: {s}", .{@errorName(failure)});
            };
        } else try std.Io.sleep(io, .fromSeconds(1), .awake);
    }
}

/// Выполняет скачивание параллельно с продлением аренды и ожиданием общего таймаута.
/// При завершении отменяет оставшиеся ветки и дожидается их остановки.
fn processTask(app: *App, arena: std.mem.Allocator, task: model.Task) !void {
    const Result = union(enum) {
        output: anyerror!void,
        heartbeat: anyerror!void,
        timeout: anyerror!void,
    };
    var buffer: [3]Result = undefined;
    var select = std.Io.Select(Result).init(app.storage.io, &buffer);
    defer select.cancelDiscard();

    try select.concurrent(.output, downloadAndPublish, .{ app, arena, task });
    try select.concurrent(.heartbeat, maintainLease, .{ app, task });
    try select.concurrent(.timeout, waitForTimeout, .{ app.storage.io, app.imports_timeout_seconds });

    switch (try select.await()) {
        .output => |result| try result,
        .heartbeat => |result| {
            try result;

            return error.LeaseLost;
        },
        .timeout => |result| {
            try result;

            return error.DownloadTimeout;
        },
    }
}

/// Продлевает аренду скачивания каждые 15 секунд до отмены или ошибки.
fn maintainLease(app: *App, task: model.Task) anyerror!void {
    while (true) {
        try std.Io.sleep(app.storage.io, .fromSeconds(15), .awake);
        try service.heartbeat(&app.db, task);
    }
}

/// Ожидает заданное число секунд; завершение ветки Select означает истечение таймаута.
fn waitForTimeout(io: std.Io, seconds: u32) anyerror!void {
    try std.Io.sleep(io, .fromSeconds(seconds), .awake);
}

/// Скачивает pending-трек через Downloader и публикует исходник через tracks_service с проверкой аренды.
/// Для уже загруженного трека пропускает скачивание; ставит подготовку HLS в очередь и завершает задачу.
fn downloadAndPublish(app: *App, arena: std.mem.Allocator, task: model.Task) anyerror!void {
    if (!tracks_model.isValidId(task.payload.track_id) or
        !tracks_model.isValidId(task.payload.user_id) or
        !tracks_model.isValidId(task.job.attempt_id.?)) return error.InvalidInput;

    const state = blk: {
        const conn = try app.db.acquire();
        defer conn.release();

        break :blk try repository.readTrackStatus(conn, arena, task.payload.user_id, task.payload.track_id);
    };

    if (state == .pending) {
        const io = app.storage.io;

        var root = try std.Io.Dir.cwd().createDirPathOpen(io, app.imports_tmp_dir, .{});
        defer root.close(io);
        const permissions: std.Io.Dir.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
        try root.createDir(io, task.job.attempt_id.?, permissions);
        defer {
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            root.deleteTree(io, task.job.attempt_id.?) catch |err| std.log.warn("Import scratch cleanup failed: {s}", .{@errorName(err)});
        }

        var dir = try root.openDir(io, task.job.attempt_id.?, .{});
        defer dir.close(io);

        const track = try model.validateTrack(task.payload.track);
        const result = try app.downloader.download(arena, io, dir, .{
            .title = track.title,
            .artist = track.artist,
        }, app.max_upload_bytes);

        const data = dir.readFileAlloc(io, result.audio_path, arena, .limited(app.max_upload_bytes)) catch |err| {
            if (err == error.StreamTooLong) return error.FileTooLarge;
            if (err == error.FileNotFound) return error.DownloadFailed;

            return err;
        };
        if (data.len == 0) return error.EmptyFile;

        _ = try tracks_service.uploadForJob(
            app,
            arena,
            task.payload.user_id,
            task.payload.track_id,
            result.content_type,
            data,
            task.job,
        );
    }

    // A retry after successful publication resumes here instead of downloading twice.
    _ = try streaming_service.enqueue(&app.db, arena, task.payload.track_id, task.payload.user_id);
    try service.complete(&app.db, task);
    std.log.info("Import track downloaded and HLS queued: {s}", .{task.payload.track_id});
}

test "disabled imports do not claim jobs or launch external processes" {
    var app: App = undefined;
    app.capabilities = .{ .web_search = false, .spotify_import = false };

    try run(&app);
}
