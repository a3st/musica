const std = @import("std");
const builtin = @import("builtin");
const App = @import("../../app.zig").App;
const tracks = @import("../tracks/model.zig");
const model = @import("model.zig");
const repository = @import("repository.zig");

// One bounded worker per node; ownership and publication are coordinated in PostgreSQL.
pub fn run(app: *App) anyerror!void {
    const io = app.storage.io;
    while (true) {
        var arena = std.heap.ArenaAllocator.init(app.storage.allocator);
        defer arena.deinit();
        const job = repository.claim(app.db, arena.allocator()) catch |err| {
            if (err == error.Canceled) return err;
            std.log.err("HLS queue unavailable: {s}", .{@errorName(err)});
            try std.Io.sleep(io, .fromSeconds(5), .awake);
            continue;
        };
        if (job) |value| {
            prepare(app, arena.allocator(), value) catch |err| {
                if (err == error.Canceled) return err;
                std.log.err("HLS preparation failed for {s}, attempt {s}: {s}", .{ value.id, value.attempt, @errorName(err) });
                // Keep the original ready; explicit POST can retry a failed conversion.
                const retry = err != error.TranscodingFailed and err != error.InvalidHlsOutput and err != error.TranscodingTimeout and err != error.FfmpegNotFound;
                repository.failed(app.db, value, retry) catch |failure| {
                    std.log.err("HLS failure update failed: {s}", .{@errorName(failure)});
                };
            };
        } else {
            try std.Io.sleep(io, .fromSeconds(1), .awake);
        }
    }
}

fn prepare(app: *App, arena: std.mem.Allocator, job: model.Job) !void {
    const Result = union(enum) { output: anyerror!void, heartbeat: anyerror!void, timeout: anyerror!void };
    var buffer: [3]Result = undefined;
    var select = std.Io.Select(Result).init(app.storage.io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.output, convert, .{ app, arena, job });
    try select.concurrent(.heartbeat, maintainLease, .{ app, job });
    try select.concurrent(.timeout, timeout, .{ app.storage.io, app.hls_timeout_seconds });
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

fn maintainLease(app: *App, job: model.Job) anyerror!void {
    while (true) {
        try std.Io.sleep(app.storage.io, .fromSeconds(10), .awake);
        try repository.heartbeat(app.db, job);
    }
}

fn timeout(io: std.Io, seconds: u32) anyerror!void {
    try std.Io.sleep(io, .fromSeconds(seconds), .awake);
}

fn convert(app: *App, arena: std.mem.Allocator, job: model.Job) anyerror!void {
    if (!tracks.validId(job.id) or !tracks.validId(job.attempt) or job.size == 0 or job.size > app.max_upload_bytes)
        return error.InvalidHlsOutput;
    const io = app.storage.io;
    var storage = app.storage;
    storage.bucket = job.bucket;
    // All local paths are generated UUIDs below an explicitly configured scratch root.
    var root = try std.Io.Dir.cwd().createDirPathOpen(io, app.hls_tmp_dir, .{});
    defer root.close(io);
    const permissions: std.Io.Dir.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
    try root.createDir(io, job.attempt, permissions);
    defer {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        root.deleteTree(io, job.attempt) catch |err| std.log.warn("HLS scratch cleanup failed: {s}", .{@errorName(err)});
    }
    var dir = try root.openDir(io, job.attempt, .{});
    defer dir.close(io);
    {
        var download = std.heap.ArenaAllocator.init(app.storage.allocator);
        defer download.deinit();
        const source = try storage.get(download.allocator(), job.key, job.size);
        if (source.len != job.size) return error.InvalidHlsOutput;
        try dir.writeFile(io, .{ .sub_path = "source", .data = source });
    }
    var child = try spawnFfmpeg(io, .{
        .argv = &.{ app.ffmpeg_path, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-protocol_whitelist", "file,pipe", "-format_whitelist", "mp3,flac,wav,ogg,aac,mov,matroska,webm", "-i", "source", "-map", "0:a:0", "-vn", "-sn", "-dn", "-threads", "1", "-filter_threads", "1", "-c:a", "aac", "-b:a", "192k", "-ac", "2", "-ar", "48000", "-f", "hls", "-hls_time", "6", "-hls_playlist_type", "vod", "-hls_list_size", "0", "-hls_segment_filename", "segment-%06d.ts", "index.m3u8" },
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
    const prefix = try std.fmt.allocPrint(arena, "tracks/{s}/hls/{s}", .{ job.id, job.attempt });
    for (0..count) |index| {
        var segment_arena = std.heap.ArenaAllocator.init(app.storage.allocator);
        defer segment_arena.deinit();
        const temporary = segment_arena.allocator();
        const name = try std.fmt.allocPrint(temporary, "segment-{d:0>6}.ts", .{index});
        const data = try dir.readFileAlloc(io, name, temporary, .limited(model.max_segment_bytes));
        if (data.len == 0) return error.InvalidHlsOutput;
        const key = try std.fmt.allocPrint(temporary, "{s}/{s}", .{ prefix, name });
        try storage.put(temporary, key, "video/mp2t", data);
    }
    const key = try std.fmt.allocPrint(arena, "{s}/index.m3u8", .{prefix});
    try storage.put(arena, key, "application/vnd.apple.mpegurl", manifest);
    try repository.finish(app.db, job, prefix, count);
    std.log.info("HLS published for {s}: {d} segments", .{ job.id, count });
}

fn spawnFfmpeg(io: std.Io, options: std.process.SpawnOptions) !std.process.Child {
    return std.process.spawn(io, options) catch |err| {
        if (err == error.Canceled) return err;
        std.log.warn("Cannot launch FFmpeg at '{s}': {s}. FFMPEG_PATH must name an executable file, not its directory.", .{ options.argv[0], @errorName(err) });
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
