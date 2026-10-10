const std = @import("std");
const builtin = @import("builtin");
const App = @import("../../app.zig").App;
const tracks_model = @import("../tracks/model.zig");
const model = @import("model.zig");
const service = @import("service.zig");

/// Обрабатывает очередь подготовки HLS до отмены; при отсутствии работы ждёт секунду, при ошибке очереди — пять.
/// Ошибки конвертации фиксирует через сервис с выбором допустимости повтора.
pub fn run(app: *App) anyerror!void {
    const io = app.storage.io;

    while (true) {
        var arena = std.heap.ArenaAllocator.init(app.storage.allocator);
        defer arena.deinit();

        const task = service.claim(&app.db, arena.allocator()) catch |err| {
            if (err == error.Canceled) return err;
            std.log.err("HLS queue unavailable: {s}", .{@errorName(err)});

            try std.Io.sleep(io, .fromSeconds(5), .awake);
            continue;
        };

        if (task) |value| {
            processTask(app, arena.allocator(), value) catch |err| {
                if (err == error.Canceled) return err;
                std.log.err("HLS preparation failed for {s}, attempt {s}: {s}", .{ value.payload.track_id, value.job.attempt_id.?, @errorName(err) });
                // Keep the original ready; explicit POST can retry a failed conversion.
                const retry = err != error.TranscodingFailed and
                    err != error.InvalidHlsOutput and
                    err != error.TranscodingTimeout and
                    err != error.FfmpegNotFound;
                service.failTask(&app.db, value, retry) catch |failure| {
                    std.log.err("HLS failure update failed: {s}", .{@errorName(failure)});
                };
            };
        } else {
            try std.Io.sleep(io, .fromSeconds(1), .awake);
        }
    }
}

/// Выполняет конвертацию параллельно с продлением аренды и ожиданием общего таймаута.
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

    try select.concurrent(.output, convertAndPublish, .{ app, arena, task });
    try select.concurrent(.heartbeat, maintainLease, .{ app, task });
    try select.concurrent(.timeout, waitForTimeout, .{ app.storage.io, app.hls_timeout_seconds });

    switch (try select.await()) {
        .output => |result| try result,
        .heartbeat => |result| {
            try result;

            return error.LeaseLost;
        },
        .timeout => |result| {
            try result;

            return error.TranscodingTimeout;
        },
    }
}

/// Продлевает аренду подготовки HLS каждые 10 секунд до отмены или ошибки.
fn maintainLease(app: *App, task: model.Task) anyerror!void {
    while (true) {
        try std.Io.sleep(app.storage.io, .fromSeconds(10), .awake);
        try service.heartbeat(&app.db, task);
    }
}

/// Ожидает заданное число секунд; завершение ветки Select означает истечение таймаута.
fn waitForTimeout(io: std.Io, seconds: u32) anyerror!void {
    try std.Io.sleep(io, .fromSeconds(seconds), .awake);
}

/// Проверяет задачу, скачивает исходник, запускает FFmpeg и загружает сегменты и манифест в S3.
/// Публикует HLS через сервис после загрузки файлов; каталог попытки удаляет также при отмене.
fn convertAndPublish(app: *App, arena: std.mem.Allocator, task: model.Task) anyerror!void {
    if (!tracks_model.isValidId(task.payload.track_id) or
        !tracks_model.isValidId(task.job.attempt_id.?) or
        task.payload.size == 0 or task.payload.size > app.max_upload_bytes)
        return error.InvalidHlsOutput;

    const io = app.storage.io;
    const storage = &app.storage;
    // All local paths are generated UUIDs below an explicitly configured scratch root.
    var root = try std.Io.Dir.cwd().createDirPathOpen(io, app.hls_tmp_dir, .{});
    defer root.close(io);
    const permissions: std.Io.Dir.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
    try root.createDir(io, task.job.attempt_id.?, permissions);
    defer {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        root.deleteTree(io, task.job.attempt_id.?) catch |err| std.log.warn("HLS scratch cleanup failed: {s}", .{@errorName(err)});
    }

    var dir = try root.openDir(io, task.job.attempt_id.?, .{});
    defer dir.close(io);

    {
        var download = std.heap.ArenaAllocator.init(app.storage.allocator);
        defer download.deinit();
        const source = try storage.getInBucket(download.allocator(), task.payload.bucket, task.payload.key, task.payload.size);
        if (source.len != task.payload.size) return error.InvalidHlsOutput;
        try dir.writeFile(io, .{ .sub_path = "source", .data = source });
    }

    var child = try spawnFfmpeg(io, .{
        .argv = &.{
            app.ffmpeg_path,
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
            "-y",

            "-protocol_whitelist",
            "file,pipe",
            "-format_whitelist",
            "mp3,flac,wav,ogg,aac,mov,matroska,webm",
            "-i",
            "source",
            "-map",
            "0:a:0",
            "-vn",
            "-sn",
            "-dn",

            "-threads",
            "1",
            "-filter_threads",
            "1",
            "-c:a",
            "aac",
            "-b:a",
            "192k",
            "-ac",
            "2",
            "-ar",
            "48000",

            "-f",
            "hls",
            "-hls_time",
            "6",
            "-hls_playlist_type",
            "vod",
            "-hls_list_size",
            "0",
            "-hls_segment_filename",
            "segment-%06d.ts",
            "index.m3u8",
        },
        .cwd = .{ .dir = dir },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
        .create_no_window = true,
    });
    defer child.kill(io);

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.TranscodingFailed,
        else => return error.TranscodingFailed,
    }

    const manifest = try dir.readFileAlloc(io, "index.m3u8", arena, .limited(model.max_manifest_bytes));
    const count = try model.segmentCount(manifest);

    const prefix = try std.fmt.allocPrint(arena, "tracks/{s}/hls/{s}", .{ task.payload.track_id, task.job.attempt_id.? });

    for (0..count) |index| {
        var segment_arena = std.heap.ArenaAllocator.init(app.storage.allocator);
        defer segment_arena.deinit();
        const temporary = segment_arena.allocator();
        const name = try std.fmt.allocPrint(temporary, "segment-{d:0>6}.ts", .{index});

        const data = try dir.readFileAlloc(io, name, temporary, .limited(model.max_segment_bytes));
        if (data.len == 0) return error.InvalidHlsOutput;
        const key = try std.fmt.allocPrint(temporary, "{s}/{s}", .{ prefix, name });
        try storage.putInBucket(temporary, task.payload.bucket, key, "video/mp2t", data);
    }

    const key = try std.fmt.allocPrint(arena, "{s}/index.m3u8", .{prefix});
    try storage.putInBucket(arena, task.payload.bucket, key, "application/vnd.apple.mpegurl", manifest);

    try service.publishHls(&app.db, task, prefix, count);
    std.log.info("HLS published for {s}: {d} segments", .{ task.payload.track_id, count });
}

/// Запускает FFmpeg без shell; отсутствие исполняемого файла переводит в FfmpegNotFound.
fn spawnFfmpeg(io: std.Io, options: std.process.SpawnOptions) !std.process.Child {
    return std.process.spawn(io, options) catch |err| {
        if (err == error.Canceled) return err;
        std.log.warn(
            "Cannot launch FFmpeg at '{s}': {s}. FFMPEG_PATH must name an executable file, not its directory.",
            .{ options.argv[0], @errorName(err) },
        );
        if (err == error.FileNotFound) return error.FfmpegNotFound;

        return err;
    };
}

test "missing FFmpeg executable has a distinct preparation error" {
    try std.testing.expectError(error.FfmpegNotFound, spawnFfmpeg(std.testing.io, .{
        .argv = &.{"musica-nonexistent-ffmpeg-0f87633b/ffmpeg"},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }));
}
