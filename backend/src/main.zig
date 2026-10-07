const std = @import("std");
const httpz = @import("httpz");
const Config = @import("config.zig").Config;
const App = @import("app.zig").App;
const database = @import("infrastructure/database.zig");
const S3 = @import("infrastructure/s3.zig").S3;
const health = @import("features/health/routes.zig");
const tracks = @import("features/tracks/routes.zig");
const playlists = @import("features/playlists/routes.zig");
const auth = @import("features/auth/routes.zig");
const streaming = @import("features/streaming/routes.zig");
const hls_worker = @import("features/streaming/worker.zig");

pub fn main(init: std.process.Init) !void {
    const config = try Config.load(init.environ_map);
    const db = try database.connect(init.io, init.gpa, config);
    defer db.deinit();
    var app: App = .{
        .db = db,
        .storage = S3.init(init.io, init.gpa, config),
        .max_upload_bytes = config.max_upload_bytes,
        .ffmpeg_path = config.ffmpeg_path,
        .hls_tmp_dir = config.hls_tmp_dir,
        .hls_timeout_seconds = config.hls_timeout_seconds,
    };
    var server = try httpz.Server(*App).init(init.io, init.gpa, .{
        .address = .{ .ip = config.http_address },
        .request = .{ .max_body_size = config.max_upload_bytes },
        .thread_pool = .{ .count = 4 },
        .timeout = .{ .request = 120 },
    }, &app);
    defer {
        server.stop();
        server.deinit();
    }

    const router = try server.router(.{});
    health.register(router);
    tracks.register(router);
    playlists.register(router);
    auth.register(router);
    streaming.register(router);

    var worker: ?std.Io.Future(anyerror!void) = if (config.hls_worker_enabled)
        try init.io.concurrent(hls_worker.run, .{&app})
    else
        null;
    defer if (worker) |*future| future.cancel(init.io) catch {};

    std.log.info("Musica API listening on {f}", .{config.http_address});
    try server.listen();
}

test {
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
