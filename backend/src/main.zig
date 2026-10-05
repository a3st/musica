const std = @import("std");
const httpz = @import("httpz");
const Config = @import("config.zig").Config;
const App = @import("app.zig").App;
const database = @import("infrastructure/database.zig");
const S3 = @import("infrastructure/s3.zig").S3;
const health = @import("features/health/routes.zig");
const tracks = @import("features/tracks/routes.zig");

pub fn main(init: std.process.Init) !void {
    const config = try Config.load(init.environ_map);
    const db = try database.connect(init.io, init.gpa, config);
    defer db.deinit();
    var app: App = .{
        .db = db,
        .storage = S3.init(init.io, init.gpa, config),
        .max_upload_bytes = config.max_upload_bytes,
    };
    var server = try httpz.Server(*App).init(init.io, init.gpa, .{
        .address = .localhost(8080),
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

    std.log.info("Musica API: http://127.0.0.1:8080", .{});
    try server.listen();
}

test {
    _ = @import("config.zig");
    _ = @import("features/tracks/model.zig");
    _ = @import("features/tracks/routes.zig");
    _ = @import("infrastructure/s3.zig");
}
