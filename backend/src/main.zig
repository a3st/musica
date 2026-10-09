const std = @import("std");
const httpz = @import("httpz");
const Config = @import("config.zig").Config;
const App = @import("app.zig").App;
const database = @import("infrastructure/database.zig");
const S3 = @import("infrastructure/s3.zig").S3;
const health_routes = @import("features/health/routes.zig");
const tracks_routes = @import("features/tracks/routes.zig");
const playlists_routes = @import("features/playlists/routes.zig");
const auth_routes = @import("features/auth/routes.zig");
const streaming_routes = @import("features/streaming/routes.zig");
const streaming_worker = @import("features/streaming/worker.zig");
const tracks_cleanup_worker = @import("features/tracks/cleanup_worker.zig");
const spotify_int_routes = @import("features/spotify_int/routes.zig");
const spotify_int_worker = @import("features/spotify_int/worker.zig");

pub fn main(init: std.process.Init) !void {
    const config = try Config.load(init.environ_map);
    var app: App = .{
        .db = try database.Database.init(init.io, init.gpa, config.database),
        .storage = S3.init(init.io, init.gpa, config.s3),
        .max_upload_bytes = config.max_upload_bytes,
        .ffmpeg_path = config.ffmpeg_path,
        .ytdlp_path = config.ytdlp_path,
        .spotify_tmp_dir = config.spotify_tmp_dir,
        .spotify_timeout_seconds = config.spotify_timeout_seconds,
        .hls_tmp_dir = config.hls_tmp_dir,
        .hls_timeout_seconds = config.hls_timeout_seconds,
        .cookie_secure = config.cookie_secure,
    };
    defer app.db.deinit();
    defer app.storage.deinit();
    var server = try httpz.Server(*App).init(init.io, init.gpa, .{
        .address = .{ .ip = config.http_address },
        .request = .{ .max_body_size = config.max_upload_bytes },
        .workers = .{ .large_buffer_count = 4, .large_buffer_size = 64 * 1024 },
        .thread_pool = .{ .count = 4 },
        .timeout = .{ .request = 120 },
    }, &app);
    defer {
        server.stop();
        server.deinit();
    }

    const router = try server.router(.{});
    health_routes.register(router);
    tracks_routes.register(router);
    playlists_routes.register(router);
    auth_routes.register(router);
    streaming_routes.register(router);
    spotify_int_routes.register(router);

    var spotify_future: ?std.Io.Future(anyerror!void) = if (config.spotify_worker_enabled)
        try init.io.concurrent(spotify_int_worker.run, .{&app})
    else
        null;
    defer if (spotify_future) |*future| future.cancel(init.io) catch {};

    var hls_future: ?std.Io.Future(anyerror!void) = if (config.hls_worker_enabled)
        try init.io.concurrent(streaming_worker.run, .{&app})
    else
        null;
    defer if (hls_future) |*future| future.cancel(init.io) catch {};

    var cleanup_future: std.Io.Future(anyerror!void) = try init.io.concurrent(tracks_cleanup_worker.run, .{&app});
    defer cleanup_future.cancel(init.io) catch {};

    std.log.info("Musica API listening on {f}", .{config.http_address});
    try server.listen();
}

test {
    _ = @import("features/spotify_int/model.zig");
    _ = @import("features/spotify_int/routes.zig");
    _ = @import("features/spotify_int/worker.zig");
    _ = @import("infrastructure/jobs/model.zig");
    _ = @import("features/playlists/model.zig");
    _ = @import("features/playlists/routes.zig");
    _ = @import("features/playlists/service.zig");
    _ = @import("features/auth/model.zig");
    _ = @import("features/auth/service.zig");
    _ = @import("config.zig");
    _ = @import("features/tracks/model.zig");
    _ = @import("features/tracks/routes.zig");
    _ = @import("features/streaming/model.zig");
    _ = @import("features/streaming/routes.zig");
    _ = @import("features/streaming/worker.zig");
    _ = @import("infrastructure/s3.zig");
}
