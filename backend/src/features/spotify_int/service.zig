const std = @import("std");
const App = @import("../../app.zig").App;
const database = @import("../../infrastructure/database.zig");
const model = @import("model.zig");
const repository = @import("repository.zig");
const jobs_repository = @import("../../infrastructure/jobs/repository.zig");
const tracks_repository = @import("../tracks/repository.zig");
const playlists_repository = @import("../playlists/repository.zig");
const auth_model = @import("../auth/model.zig");

pub fn create(app: *App, arena: std.mem.Allocator, user: []const u8, input: model.Import) !model.Result {
    try model.validate(input);
    const token = try auth_model.newToken(app.storage.io);
    const id = try std.fmt.allocPrint(arena, "{s}-{s}-{s}-{s}-{s}", .{ token[0..8], token[8..12], token[12..16], token[16..20], token[20..32] });
    const conn = try app.db.acquire();
    defer conn.release();
    try conn.begin();
    errdefer conn.rollback() catch {};
    var tracks: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer tracks.deinit(arena);
    const playlists = try arena.alloc([]const u8, input.playlists.len);
    for (input.playlists, 0..) |playlist, index| {
        playlists[index] = try playlists_repository.create(conn, arena, user, std.mem.trim(u8, playlist.title, " \t\r\n"), playlist.description, "[]", "private");
        for (playlist.tracks) |track| {
            const track_id = try createTrack(conn, arena, app.storage.bucket, user, id, track, &tracks);
            try playlists_repository.addTrack(conn, arena, playlists[index], user, track_id);
        }
    }
    for (input.library) |track| _ = try createTrack(conn, arena, app.storage.bucket, user, id, track, &tracks);
    try conn.commit();
    return .{ .id = id, .tracks = tracks.count(), .playlists = playlists };
}

fn createTrack(conn: *database.Connection, arena: std.mem.Allocator, bucket: []const u8, user: []const u8, import_id: []const u8, track: model.Track, tracks: *std.StringHashMapUnmanaged([]const u8)) ![]const u8 {
    const entry = try tracks.getOrPut(arena, try model.identity(arena, track));
    if (entry.found_existing) return entry.value_ptr.*;
    const created = try tracks_repository.create(conn, arena, user, bucket, .{ .title = std.mem.trim(u8, track.title, " \t\r\n"), .artist = std.mem.trim(u8, track.artist, " \t\r\n") });
    const id = try arena.dupe(u8, &created);
    entry.value_ptr.* = id;
    _ = try jobs_repository.enqueue(conn, arena, model.download_job_kind, id, model.Payload{ .import_id = import_id, .user_id = user, .track_id = id, .track = track }, 0, 3);
    return id;
}

pub fn status(db: *database.Database, arena: std.mem.Allocator, user: []const u8, id: []const u8) ![]const u8 {
    const conn = try db.acquire();
    defer conn.release();
    return repository.status(conn, arena, user, try std.ascii.allocLowerString(arena, id));
}

pub fn retry(db: *database.Database, arena: std.mem.Allocator, user: []const u8, id: []const u8) ![]const u8 {
    const conn = try db.acquire();
    defer conn.release();
    try conn.begin();
    errdefer conn.rollback() catch {};
    const canonical = try std.ascii.allocLowerString(arena, id);
    _ = try repository.status(conn, arena, user, canonical);
    try repository.retry(conn, user, canonical);
    const result = try repository.status(conn, arena, user, canonical);
    try conn.commit();
    return result;
}

pub fn claim(db: *database.Database, arena: std.mem.Allocator) !?model.Task {
    const conn = try db.acquire();
    defer conn.release();
    const job = (try jobs_repository.claim(conn, arena, model.download_job_kind, 120)) orelse return null;
    const payload = job.decodePayload(model.Payload, arena) catch |err| {
        try jobs_repository.fail(conn, job, false, 0);
        return err;
    };
    return .{ .job = job, .payload = payload };
}

pub fn heartbeat(db: *database.Database, task: model.Task) !void {
    const conn = try db.acquire();
    defer conn.release();
    try jobs_repository.heartbeat(conn, task.job, 120);
}

pub fn finish(db: *database.Database, task: model.Task) !void {
    const conn = try db.acquire();
    defer conn.release();
    try jobs_repository.complete(conn, task.job);
}

pub fn failed(db: *database.Database, task: model.Task, retryable: bool) !void {
    const conn = try db.acquire();
    defer conn.release();
    jobs_repository.fail(conn, task.job, retryable, 30) catch |err| if (err != error.LeaseLost) return err;
}
