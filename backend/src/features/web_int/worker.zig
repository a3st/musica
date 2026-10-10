const std = @import("std");
const builtin = @import("builtin");
const App = @import("../../app.zig").App;
const model = @import("model.zig");
const service = @import("service.zig");
const repository = @import("repository.zig");
const tracks_model = @import("../tracks/model.zig");
const tracks_service = @import("../tracks/service.zig");
const streaming_service = @import("../streaming/service.zig");

pub fn run(app: *App) anyerror!void {
    const io = app.storage.io;
    while (true) {
        var arena = std.heap.ArenaAllocator.init(app.storage.allocator);
        defer arena.deinit();
        const task = service.claim(&app.db, arena.allocator()) catch |err| {
            if (err == error.Canceled) return err;
            std.log.err("Web queue unavailable: {s}", .{@errorName(err)});
            try std.Io.sleep(io, .fromSeconds(5), .awake);
            continue;
        };
        if (task) |value| {
            process(app, arena.allocator(), value) catch |err| {
                if (err == error.Canceled) return err;
                std.log.err("Web download failed for {s}, attempt {s}: {s}", .{ value.payload.track_id, value.job.attempt_id.?, @errorName(err) });
                const retryable = err != error.FileNotFound and err != error.InvalidInput and err != error.InvalidText and err != error.TrackNotFound and err != error.FileTooLarge;
                service.failed(&app.db, value, retryable) catch |failure| std.log.err("Web job failure update failed: {s}", .{@errorName(failure)});
            };
        } else try std.Io.sleep(io, .fromSeconds(1), .awake);
    }
}

fn process(app: *App, arena: std.mem.Allocator, task: model.Task) !void {
    const Result = union(enum) { output: anyerror!void, heartbeat: anyerror!void, timeout: anyerror!void };
    var buffer: [3]Result = undefined;
    var select = std.Io.Select(Result).init(app.storage.io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.output, download, .{ app, arena, task });
    try select.concurrent(.heartbeat, maintainLease, .{ app, task });
    try select.concurrent(.timeout, timeout, .{ app.storage.io, app.spotify_timeout_seconds });
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

fn maintainLease(app: *App, task: model.Task) anyerror!void {
    while (true) {
        try std.Io.sleep(app.storage.io, .fromSeconds(15), .awake);
        try service.heartbeat(&app.db, task);
    }
}

fn timeout(io: std.Io, seconds: u32) anyerror!void {
    try std.Io.sleep(io, .fromSeconds(seconds), .awake);
}

pub fn arguments(app: *App, arena: std.mem.Allocator, track: model.Track) ![]const []const u8 {
    _ = try tracks_model.validateCreate(.{ .title = track.title, .artist = track.artist });
    const query = try std.fmt.allocPrint(arena, "ytsearch1:{s} {s}", .{ std.mem.trim(u8, track.artist, " \t\r\n"), std.mem.trim(u8, track.title, " \t\r\n") });
    const max_size = try std.fmt.allocPrint(arena, "{d}", .{app.max_upload_bytes});
    // No shell, user URL or filename is accepted; the search is always one argv element.
    return arena.dupe([]const u8, &.{ app.ytdlp_path, "--ignore-config", "--no-playlist", "--no-progress", "--socket-timeout", "30", "--retries", "2", "--max-filesize", max_size, "--js-runtimes", "node", "-f", "bestaudio/best", "-x", "--audio-format", "mp3", "--audio-quality", "256K", "--embed-metadata", "--embed-thumbnail", "--convert-thumbnails", "jpg", "--write-thumbnail", "--ffmpeg-location", app.ffmpeg_path, "--output", "source.%(ext)s", "--", query });
}

fn download(app: *App, arena: std.mem.Allocator, task: model.Task) anyerror!void {
    if (!tracks_model.validId(task.payload.track_id) or !tracks_model.validId(task.payload.user_id) or !tracks_model.validId(task.job.attempt_id.?)) return error.InvalidInput;
    const state = blk: {
        const conn = try app.db.acquire();
        defer conn.release();
        break :blk try repository.readTrackStatus(conn, arena, task.payload.user_id, task.payload.track_id);
    };
    if (state == .pending) {
        const io = app.storage.io;
        var root = try std.Io.Dir.cwd().createDirPathOpen(io, app.spotify_tmp_dir, .{});
        defer root.close(io);
        const permissions: std.Io.Dir.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
        try root.createDir(io, task.job.attempt_id.?, permissions);
        defer {
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            root.deleteTree(io, task.job.attempt_id.?) catch |err| std.log.warn("Web scratch cleanup failed: {s}", .{@errorName(err)});
        }
        var dir = try root.openDir(io, task.job.attempt_id.?, .{});
        defer dir.close(io);
        var child = std.process.spawn(io, .{
            .argv = try arguments(app, arena, task.payload.track),
            .cwd = .{ .dir = dir },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
            .create_no_window = true,
        }) catch |err| {
            std.log.err("Cannot launch yt-dlp at '{s}': {s}", .{ app.ytdlp_path, @errorName(err) });
            return err;
        };
        defer child.kill(io);
        switch (try child.wait(io)) {
            .exited => |code| if (code != 0) return error.DownloadFailed,
            else => return error.DownloadFailed,
        }
        const data = dir.readFileAlloc(io, "source.mp3", arena, .limited(app.max_upload_bytes)) catch |err| {
            if (err == error.StreamTooLong) return error.FileTooLarge;
            return err;
        };
        if (data.len == 0) return error.EmptyFile;
        _ = try tracks_service.uploadForJob(app, arena, task.payload.user_id, task.payload.track_id, "audio/mpeg", data, task.job);
    }
    // A retry after successful publication resumes here instead of downloading twice.
    _ = try streaming_service.enqueue(&app.db, arena, task.payload.track_id, task.payload.user_id);
    try service.finish(&app.db, task);
    std.log.info("Web track downloaded and HLS queued: {s}", .{task.payload.track_id});
}

test "yt-dlp uses fixed output, MP3 bitrate and artwork; search stays a single argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var app: App = .{ .db = undefined, .storage = undefined, .max_upload_bytes = 1024, .ffmpeg_path = "C:\\Program Files\\FFmpeg\\bin\\ffmpeg.exe" };
    const argv = try arguments(&app, arena.allocator(), .{ .title = "Title \"; echo hi", .artist = "Artist" });
    try std.testing.expectEqualStrings("ytsearch1:Artist Title \"; echo hi", argv[argv.len - 1]);
    try std.testing.expectEqualStrings("--", argv[argv.len - 2]);
    var bitrate = false;
    var cover = false;
    for (argv, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "--audio-quality")) bitrate = std.mem.eql(u8, argv[index + 1], "256K");
        if (std.mem.eql(u8, arg, "--embed-thumbnail")) cover = true;
    }
    try std.testing.expect(bitrate and cover);
}
