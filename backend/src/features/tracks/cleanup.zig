const std = @import("std");
const App = @import("../../app.zig").App;
const sql = @import("../../helpers/sql.zig");

const Job = struct { id: []const u8, bucket: []const u8, keys: []const []const u8, attempt: []const u8 };

pub fn run(app: *App) anyerror!void {
    const io = app.storage.io;
    while (true) {
        var arena = std.heap.ArenaAllocator.init(app.storage.allocator);
        defer arena.deinit();
        cycle(app, arena.allocator()) catch |err| {
            if (err == error.Canceled) return err;
            std.log.err("Track cleanup failed: {s}", .{@errorName(err)});
        };
        try std.Io.sleep(io, .fromSeconds(1), .awake);
    }
}

fn cycle(app: *App, arena: std.mem.Allocator) !void {
    const body = blk: {
        const conn = app.db.acquire() catch return error.DatabaseUnavailable;
        defer conn.release();
        break :blk (try sql.text(conn, arena, "WITH candidate AS (SELECT id FROM track_file_deletions WHERE (state='queued' AND available_at<=now()) OR (state='processing' AND lease_until<now()) ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1) UPDATE track_file_deletions j SET state='processing', attempt_id=gen_random_uuid(), lease_until=now()+interval '120 seconds' FROM candidate c WHERE j.id=c.id RETURNING json_build_object('id',j.id,'bucket',j.bucket,'keys',j.object_keys,'attempt',j.attempt_id)::text", .{})) orelse return;
    };
    const job = try std.json.parseFromSliceLeaky(Job, arena, body, .{});
    const Result = union(enum) { output: anyerror!void, lease: anyerror!void };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(app.storage.io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.output, deleteFiles, .{ app, job });
    try select.concurrent(.lease, renew, .{ app, job });
    const result = switch (try select.await()) {
        .output => |value| value,
        .lease => |value| value,
    };
    // Join canceled work before returning its job to the queue.
    select.cancelDiscard();
    const conn = app.db.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    result catch |err| {
        if (err == error.Canceled) return err;
        _ = try sql.exec(conn, "UPDATE track_file_deletions SET state='queued', lease_until=NULL, available_at=now()+interval '30 seconds' WHERE id=$1 AND attempt_id=$2 AND lease_until>clock_timestamp()", .{ job.id, job.attempt });
        return err;
    };
    _ = try sql.exec(conn, "DELETE FROM track_file_deletions WHERE id=$1 AND attempt_id=$2 AND lease_until>clock_timestamp()", .{ job.id, job.attempt });
}

fn deleteFiles(app: *App, job: Job) anyerror!void {
    var storage = app.storage;
    storage.bucket = job.bucket;
    for (job.keys) |key| {
        var arena = std.heap.ArenaAllocator.init(app.storage.allocator);
        defer arena.deinit();
        try storage.delete(arena.allocator(), key);
    }
}

fn renew(app: *App, job: Job) anyerror!void {
    while (true) {
        try std.Io.sleep(app.storage.io, .fromSeconds(15), .awake);
        const conn = app.db.acquire() catch return error.DatabaseUnavailable;
        defer conn.release();
        if (try sql.exec(conn, "UPDATE track_file_deletions SET lease_until=now()+interval '120 seconds' WHERE id=$1 AND attempt_id=$2 AND lease_until>clock_timestamp()", .{ job.id, job.attempt }) != 1) return error.LeaseLost;
    }
}
