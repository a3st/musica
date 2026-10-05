const std = @import("std");
const pg = @import("pg");
const Config = @import("../config.zig").Config;

pub fn connect(io: std.Io, allocator: std.mem.Allocator, config: Config) !*pg.Pool {
    return pg.Pool.init(io, allocator, .{
        .size = 4,
        .timeout = 5000,
        .connect = .{ .host = config.pg_host, .port = config.pg_port },
        .auth = .{
            .username = config.pg_user,
            .password = config.pg_password,
            .database = config.pg_database,
            .application_name = "musica",
            .timeout = 5000,
        },
    });
}
