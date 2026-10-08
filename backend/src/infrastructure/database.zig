const std = @import("std");
const pg = @import("pg");

pub const Settings = struct {
    host: []const u8,
    port: u16,
    name: []const u8,
    username: []const u8,
    password: []const u8,

    pub fn load(env: *const std.process.Environ.Map) !Settings {
        const password = env.get("PGPASSWORD") orelse {
            std.log.err("Missing environment variable: PGPASSWORD", .{});
            return error.MissingConfiguration;
        };
        const settings: Settings = .{
            .host = env.get("PGHOST") orelse "127.0.0.1",
            .port = try std.fmt.parseInt(u16, env.get("PGPORT") orelse "5432", 10),
            .name = env.get("PGDATABASE") orelse "musica",
            .username = env.get("PGUSER") orelse "musica",
            .password = password,
        };
        if (settings.port == 0 or settings.host.len == 0 or settings.name.len == 0 or settings.username.len == 0 or settings.password.len == 0)
            return error.InvalidConfiguration;
        return settings;
    }
};

// Owns the pool. Keep one owner and release borrowed connections before deinit.
pub const Database = struct {
    pool: *pg.Pool,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, config: Settings) !Database {
        const pool = pg.Pool.init(io, allocator, .{
            .size = 4,
            .timeout = 5000,
            .connect = .{ .host = config.host, .port = config.port },
            .auth = .{
                .username = config.username,
                .password = config.password,
                .database = config.name,
                .application_name = "musica",
                .timeout = 5000,
            },
        }) catch |err| {
            std.log.err("Database initialization failed: {s}", .{@errorName(err)});
            return error.DatabaseUnavailable;
        };
        return .{ .pool = pool };
    }

    pub fn acquire(self: *Database) !*Connection {
        return @ptrCast(self.pool.acquire() catch return error.DatabaseUnavailable);
    }

    pub fn deinit(self: *Database) void {
        self.pool.deinit();
        self.* = undefined;
    }
};

pub const Connection = opaque {
    fn driver(self: *Connection) *pg.Conn {
        return @ptrCast(@alignCast(self));
    }

    pub fn release(self: *Connection) void {
        self.driver().release();
    }

    pub fn begin(self: *Connection) !void {
        self.driver().begin() catch |err| return failure(self.driver(), err);
    }

    pub fn commit(self: *Connection) !void {
        self.driver().commit() catch |err| return failure(self.driver(), err);
    }

    pub fn rollback(self: *Connection) !void {
        self.driver().rollback() catch |err| return failure(self.driver(), err);
    }

    pub fn text(self: *Connection, arena: std.mem.Allocator, query: []const u8, values: anytype) !?[]const u8 {
        const conn = self.driver();
        var row = (conn.rowOpts(query, values, .{ .timeout = 10000 }) catch |err| return failure(conn, err)) orelse return null;
        var finished = false;
        defer if (!finished) row.deinit() catch {};
        // The driver owns response memory until QueryRow.deinit; copy before releasing it.
        const value = try arena.dupe(u8, row.get([]const u8, 0) catch |err| return failure(conn, err));
        finished = true;
        row.deinit() catch |err| return failure(conn, err);
        return value;
    }

    pub fn exec(self: *Connection, query: []const u8, values: anytype) !i64 {
        const conn = self.driver();
        return (conn.execOpts(query, values, .{ .timeout = 10000 }) catch |err| return failure(conn, err)) orelse 0;
    }
};

fn failure(conn: *pg.Conn, err: anyerror) anyerror {
    if (err == error.PG) {
        if (conn.err) |details| {
            if (std.mem.eql(u8, details.code, "23505")) return error.Conflict;
            if (std.mem.eql(u8, details.code, "23503")) return error.ReferenceNotFound;
            if (std.mem.eql(u8, details.code, "23514")) return error.InvalidInput;
            if (std.mem.eql(u8, details.code, "55P03")) return error.LockUnavailable;
            // Never log SQL text, parameters, or the server's free-form message.
            std.log.err("PostgreSQL operation failed: SQLSTATE {s}", .{details.code});
            return error.DatabaseUnavailable;
        }
    }
    std.log.err("PostgreSQL operation failed: {s}", .{@errorName(err)});
    return error.DatabaseUnavailable;
}
