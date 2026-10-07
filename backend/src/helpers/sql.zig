const std = @import("std");
const pg = @import("pg");

pub fn failure(conn: *pg.Conn, err: anyerror) anyerror {
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

// Copy the value before QueryRow releases PostgreSQL's response buffer.
pub fn text(conn: *pg.Conn, arena: std.mem.Allocator, query: []const u8, values: anytype) !?[]const u8 {
    var row = (conn.rowOpts(query, values, .{ .timeout = 10000 }) catch |err| return failure(conn, err)) orelse return null;
    var finished = false;
    defer if (!finished) row.deinit() catch {};
    const value = try arena.dupe(u8, row.get([]const u8, 0) catch |err| return failure(conn, err));
    finished = true;
    row.deinit() catch |err| return failure(conn, err);
    return value;
}

pub fn exec(conn: *pg.Conn, query: []const u8, values: anytype) !i64 {
    return (conn.execOpts(query, values, .{ .timeout = 10000 }) catch |err| return failure(conn, err)) orelse 0;
}
