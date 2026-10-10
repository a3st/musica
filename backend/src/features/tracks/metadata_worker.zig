const std = @import("std");
const builtin = @import("builtin");
const App = @import("../../app.zig").App;
const auth_model = @import("../auth/model.zig");
const model = @import("model.zig");
const service = @import("metadata_service.zig");

/// Метаданные ffprobe; artwork_stream указывает только встроенную картинку, а не видеодорожку.
const Probe = struct {
    duration_seconds: ?u32,
    artwork_stream: ?u32,
};

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

    const probe_path = try resolveFfprobePath(arena, app.ffmpeg_path, app.ffprobe_path);
    const probe_output = try runTool(arena, io, dir, &.{
        probe_path,          "-v",                                     "error",         "-protocol_whitelist",                                                     "file,pipe",
        "-format_whitelist", "mp3,flac,wav,ogg,aac,mov,matroska,webm", "-show_entries", "format=duration:stream=index,codec_type:stream_disposition=attached_pic", "-of",
        "json",              "source",
    });
    const probe = try parseProbe(arena, probe_output);
    var metadata: model.Metadata = .{ .duration_seconds = probe.duration_seconds, .artwork_key = null };
    var reservation: ?[]const u8 = null;

    if (probe.artwork_stream) |index| {
        const stream = try std.fmt.allocPrint(arena, "0:{d}", .{index});
        // A damaged embedded picture must not prevent publication of the audio duration.
        _ = runTool(arena, io, dir, &.{
            app.ffmpeg_path,       "-hide_banner",    "-loglevel",                                          "error",                                  "-nostdin", "-y",
            "-protocol_whitelist", "file,pipe",       "-format_whitelist",                                  "mp3,flac,wav,ogg,aac,mov,matroska,webm", "-i",       "source",
            "-map",                stream,            "-frames:v",                                          "1",                                      "-an",      "-sn",
            "-dn",                 "-vf",             "scale=600:600:force_original_aspect_ratio=decrease", "-q:v",                                   "3",        "-threads",
            "1",                   "-filter_threads", "1",                                                  "artwork.jpg",
        }) catch |err| {
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

/// Находит ffprobe рядом с явно заданным FFmpeg, если отдельный путь не переопределён.
fn resolveFfprobePath(arena: std.mem.Allocator, ffmpeg: []const u8, configured: []const u8) ![]const u8 {
    if (!std.mem.eql(u8, configured, "ffprobe")) return configured;
    const directory = std.fs.path.dirname(ffmpeg) orelse return configured;
    return std.fs.path.join(arena, &.{ directory, if (builtin.os.tag == .windows) "ffprobe.exe" else "ffprobe" });
}

/// Запускает инструмент без shell; ограничивает вывод и логирует диагностику неуспешного процесса.
fn runTool(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, argv: []const []const u8) ![]const u8 {
    const result = try std.process.run(arena, io, .{
        .argv = argv,
        .cwd = .{ .dir = dir },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .create_no_window = true,
    });

    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    std.log.warn("Media metadata tool failed: {s}", .{result.stderr});
    return error.InvalidMedia;
}

/// Проверяет ответ ffprobe; округляет секунды и исключает обычные видеодорожки из обложек.
fn parseProbe(arena: std.mem.Allocator, body: []const u8) !Probe {
    const Stream = struct {
        index: u32,
        codec_type: []const u8,
        disposition: struct { attached_pic: u8 = 0 } = .{},
    };
    const parsed = std.json.parseFromSliceLeaky(struct {
        format: struct { duration: ?[]const u8 = null } = .{},
        streams: []const Stream,
    }, arena, body, .{ .ignore_unknown_fields = true }) catch return error.InvalidMedia;

    var result: Probe = .{ .duration_seconds = null, .artwork_stream = null };
    var audio = false;
    for (parsed.streams) |stream| {
        if (std.mem.eql(u8, stream.codec_type, "audio")) audio = true;
        if (std.mem.eql(u8, stream.codec_type, "video") and stream.disposition.attached_pic == 1 and result.artwork_stream == null)
            result.artwork_stream = stream.index;
    }
    if (!audio) return error.InvalidMedia;
    if (parsed.format.duration) |value| {
        const seconds = std.fmt.parseFloat(f64, value) catch return error.InvalidMedia;
        const rounded = @round(seconds);
        if (!std.math.isFinite(seconds) or seconds < 0 or rounded > std.math.maxInt(i32)) return error.InvalidMedia;
        result.duration_seconds = @intFromFloat(rounded);
    }
    return result;
}

test "probe rounds seconds and uses only attached artwork" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parseProbe(arena.allocator(),
        \\{"format":{"duration":"182.6"},"streams":[{"index":0,"codec_type":"audio"},{"index":1,"codec_type":"video"},{"index":2,"codec_type":"video","disposition":{"attached_pic":1}}]}
    );
    try std.testing.expectEqual(@as(?u32, 183), result.duration_seconds);
    try std.testing.expectEqual(@as(?u32, 2), result.artwork_stream);
    const unknown = try parseProbe(arena.allocator(), "{\"streams\":[{\"index\":0,\"codec_type\":\"audio\"}]}");
    try std.testing.expect(unknown.duration_seconds == null and unknown.artwork_stream == null);
    for ([_][]const u8{ "-1", "nan", "inf", "2147483648", "broken" }) |duration| {
        const body = try std.fmt.allocPrint(arena.allocator(), "{{\"format\":{{\"duration\":\"{s}\"}},\"streams\":[{{\"index\":0,\"codec_type\":\"audio\"}}]}}", .{duration});
        try std.testing.expectError(error.InvalidMedia, parseProbe(arena.allocator(), body));
    }
    try std.testing.expectError(error.InvalidMedia, parseProbe(arena.allocator(), "{\"streams\":[{\"index\":0,\"codec_type\":\"video\"}]}"));
}
