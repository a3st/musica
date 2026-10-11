const std = @import("std");
const httpz = @import("httpz");

const Config = @import("config.zig").Config;
const App = @import("app.zig").App;

const Database = @import("infrastructure/database.zig").Database;
const S3 = @import("infrastructure/s3.zig").S3;
const Catalog = @import("infrastructure/catalog/catalog.zig").Catalog;
const Probe = @import("infrastructure/media/probe.zig").Probe;
const FFmpeg = @import("infrastructure/media/ffmpeg.zig").FFmpeg;
const Downloader = @import("infrastructure/downloader/downloader.zig").Downloader;

const health_routes = @import("features/health/routes.zig");
const capabilities_routes = @import("features/capabilities/routes.zig");
const tracks_routes = @import("features/tracks/routes.zig");
const playlists_routes = @import("features/playlists/routes.zig");
const auth_routes = @import("features/auth/routes.zig");
const streaming_routes = @import("features/streaming/routes.zig");
const streaming_worker = @import("features/streaming/worker.zig");
const tracks_cleanup_worker = @import("features/tracks/cleanup_worker.zig");
const tracks_metadata_worker = @import("features/tracks/metadata_worker.zig");
const spotify_int_routes = @import("features/spotify_int/routes.zig");
const imports_worker = @import("features/imports/worker.zig");
const web_int_routes = @import("features/web_int/routes.zig");
const users_service = @import("features/users/service.zig");
const profile_routes = @import("features/profile/routes.zig");
const admin_routes = @import("features/admin/routes.zig");
const web_int_cleanup_worker = @import("features/web_int/cleanup_worker.zig");

/// Создаёт ресурсы приложения, регистрирует маршруты и запускает сервер и фоновые задачи.
/// При завершении останавливает фоновые задачи и сервер перед освобождением S3 и БД.
pub fn main(init: std.process.Init) !void {
    const config = try Config.load(init.environ_map);

    var app: App = .{
        .allocator = init.gpa,
        .io = init.io,

        .db = try Database.init(init.io, init.gpa, config.database),
        .storage = S3.init(init.io, init.gpa, config.s3),
        .catalog = Catalog.init(init.io, init.gpa),
        .probe = Probe.init(config.ffprobe_path),
        .ffmpeg = FFmpeg.init(config.ffmpeg_path),
        .downloader = Downloader.init(.{
            .ytdlp_path = config.ytdlp_path,
            .ffmpeg_path = config.ffmpeg_path,
            .providers = &.{.yt_dlp},
        }),

        .max_upload_bytes = config.max_upload_bytes,
        .metadata_tmp_dir = config.metadata_tmp_dir,
        .metadata_timeout_seconds = config.metadata_timeout_seconds,

        .imports_tmp_dir = config.imports_tmp_dir,
        .imports_timeout_seconds = config.imports_timeout_seconds,

        .hls_tmp_dir = config.hls_tmp_dir,
        .hls_timeout_seconds = config.hls_timeout_seconds,

        .cookie_secure = config.cookie_secure,
        .registration_enabled = config.registration_enabled,
        .capabilities = .{
            .web_search = config.web_int_enabled,
            .spotify_import = config.spotify_int_enabled,
        },

        .shared_track_retention_seconds = config.shared_track_retention_seconds,
    };
    defer app.db.deinit();
    defer app.storage.deinit();
    defer app.catalog.deinit();

    {
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();

        try users_service.bootstrap(
            &app,
            arena.allocator(),
            config.bootstrap_admin_username,
            config.bootstrap_admin_password,
        );
    }

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
    capabilities_routes.register(router);
    tracks_routes.register(router);
    playlists_routes.register(router);
    auth_routes.register(router);
    profile_routes.register(router);
    admin_routes.register(router);
    streaming_routes.register(router);
    if (config.spotify_int_enabled) spotify_int_routes.register(router);
    if (config.web_int_enabled) web_int_routes.register(router);

    var imports_future: ?std.Io.Future(anyerror!void) = if (config.importsEnabled() and config.imports_worker_enabled)
        try init.io.concurrent(imports_worker.run, .{&app})
    else
        null;
    defer if (imports_future) |*future| future.cancel(init.io) catch {};

    var hls_future: ?std.Io.Future(anyerror!void) = if (config.hls_worker_enabled)
        try init.io.concurrent(streaming_worker.run, .{&app})
    else
        null;
    defer if (hls_future) |*future| future.cancel(init.io) catch {};

    var tracks_cleanup_future: std.Io.Future(anyerror!void) = try init.io.concurrent(tracks_cleanup_worker.run, .{&app});
    defer tracks_cleanup_future.cancel(init.io) catch {};

    var metadata_future: ?std.Io.Future(anyerror!void) = if (config.metadata_worker_enabled)
        try init.io.concurrent(tracks_metadata_worker.run, .{&app})
    else
        null;
    defer if (metadata_future) |*future| future.cancel(init.io) catch {};

    var unused_future: std.Io.Future(anyerror!void) = try init.io.concurrent(web_int_cleanup_worker.run, .{&app});
    defer unused_future.cancel(init.io) catch {};

    std.log.info("Musica API listening on {f}", .{config.http_address});

    try server.listen();
}

test {
    _ = @import("helpers/passwords.zig");
    _ = @import("features/users/model.zig");
    _ = @import("features/profile/routes.zig");
    _ = @import("features/admin/routes.zig");
    _ = @import("features/profile/model.zig");
    _ = @import("helpers/retry.zig");
    _ = @import("infrastructure/downloader/providers/yt_dlp.zig");
    _ = @import("infrastructure/downloader/downloader.zig");
    _ = @import("infrastructure/media/ffmpeg.zig");
    _ = @import("infrastructure/media/probe.zig");
    _ = @import("features/capabilities/routes.zig");
    _ = @import("infrastructure/catalog/catalog.zig");
    _ = @import("features/tracks/metadata_worker.zig");
    _ = @import("features/web_int/routes.zig");
    _ = @import("infrastructure/catalog/providers/itunes.zig");
    _ = @import("infrastructure/catalog/providers/deezer.zig");
    _ = @import("features/spotify_int/model.zig");
    _ = @import("features/spotify_int/routes.zig");
    _ = @import("features/imports/worker.zig");
    _ = @import("features/imports/service.zig");
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
