const std = @import("std");
const App = @import("../../app.zig").App;
const model = @import("model.zig");
const database = @import("../../infrastructure/database.zig");
const repository = @import("repository.zig");
const tracks_operations = @import("../tracks/operations.zig");
const tracks_cleanup_service = @import("../tracks/cleanup_service.zig");
const auth_model = @import("../auth/model.zig");

pub fn create(app: *App, arena: std.mem.Allocator, user: []const u8, raw: model.CreatePlaylist) ![]const u8 {
    const input = try model.validateCreate(raw);
    const tags = try std.json.Stringify.valueAlloc(arena, input.tags, .{});
    return createRecord(&app.db, arena, user, input.title, input.description, tags, @tagName(input.visibility));
}

pub fn update(app: *App, arena: std.mem.Allocator, user: []const u8, id: []const u8, raw: model.CreatePlaylist) !void {
    const input = try model.validateCreate(raw);
    const tags = try std.json.Stringify.valueAlloc(arena, input.tags, .{});
    try updateRecord(&app.db, arena, id, user, input.title, input.description, tags, @tagName(input.visibility));
}

pub fn createLink(app: *App, arena: std.mem.Allocator, user: []const u8, id: []const u8) ![64]u8 {
    const token = try auth_model.newToken(app.storage.io);
    const hash = auth_model.tokenHash(&token);
    try link(&app.db, arena, id, user, &hash);
    return token;
}

pub fn image(app: *App, arena: std.mem.Allocator, user: []const u8, id: []const u8, mime: []const u8, data: []const u8) ![]const u8 {
    if (!validImage(mime, data)) return error.InvalidInput;
    const token = try auth_model.newToken(app.storage.io);
    const key = try std.fmt.allocPrint(arena, "playlists/{s}/{s}", .{ id, &token });
    const reservation = blk: {
        const conn = try app.db.acquire();
        defer conn.release();
        try conn.begin();
        errdefer conn.rollback() catch {};
        try repository.requireWrite(conn, arena, id, user, false);
        if (try repository.isDefault(conn, arena, id)) return error.DefaultPlaylistProtected;
        const value = try tracks_cleanup_service.reserve(conn, arena, app.storage.bucket, key);
        try conn.commit();
        break :blk value;
    };
    app.storage.put(arena, key, mime, data) catch |err| {
        std.log.err("Playlist image storage upload failed: {s}", .{@errorName(err)});
        if (err == error.Canceled) return err;
        if (err == error.StorageTimeout) return error.StorageTimeout;
        return error.StorageUnavailable;
    };
    {
        const conn = try app.db.acquire();
        defer conn.release();
        try conn.begin();
        errdefer conn.rollback() catch {};
        // Recheck permissions: an editor can be revoked while S3 is receiving the image.
        try repository.requireWrite(conn, arena, id, user, false);
        if (try repository.isDefault(conn, arena, id)) return error.DefaultPlaylistProtected;
        try repository.setImage(conn, id, key);
        try tracks_cleanup_service.publish(conn, reservation);
        try conn.commit();
    }
    return key;
}

pub fn validImage(mime: []const u8, data: []const u8) bool {
    if (std.mem.eql(u8, mime, "image/png")) return std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n");
    if (std.mem.eql(u8, mime, "image/jpeg")) return std.mem.startsWith(u8, data, "\xff\xd8\xff");
    if (std.mem.eql(u8, mime, "image/webp")) return data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP");
    return false;
}

test "playlist covers reject active formats and mismatching file signatures" {
    try std.testing.expect(validImage("image/png", "\x89PNG\r\n\x1a\nbytes"));
    try std.testing.expect(!validImage("image/png", "<html>"));
    try std.testing.expect(!validImage("image/svg+xml", "<svg/>"));
    try std.testing.expect(!validImage("image/webp", "RIFF"));
}

pub fn list(db: *database.Database, arena: std.mem.Allocator, user: []const u8) ![]const u8 {
    const conn = try db.acquire();
    defer conn.release();
    const result = try repository.list(conn, arena, user);
    return result;
}

pub fn read(db: *database.Database, arena: std.mem.Allocator, id: []const u8, user: ?[]const u8) ![]const u8 {
    const conn = try db.acquire();
    defer conn.release();
    const result = try repository.read(conn, arena, id, user);
    return result;
}

pub fn readShared(db: *database.Database, arena: std.mem.Allocator, hash: []const u8) ![]const u8 {
    const conn = try db.acquire();
    defer conn.release();
    const result = try repository.readShared(conn, arena, hash);
    return result;
}

pub fn setMemberRole(db: *database.Database, arena: std.mem.Allocator, id: []const u8, owner: []const u8, user: []const u8, role: []const u8) !void {
    const conn = try db.acquire();
    defer conn.release();
    try conn.begin();
    errdefer conn.rollback() catch {};
    try repository.requireWrite(conn, arena, id, owner, true);
    if (try repository.isDefault(conn, arena, id)) return error.DefaultPlaylistProtected;
    if (std.ascii.eqlIgnoreCase(owner, user)) return error.InvalidInput;
    try repository.setMemberRole(conn, id, user, role);
    try conn.commit();
}

pub fn removeMember(db: *database.Database, arena: std.mem.Allocator, id: []const u8, owner: []const u8, user: []const u8) !void {
    const conn = try db.acquire();
    defer conn.release();
    try conn.begin();
    errdefer conn.rollback() catch {};
    try repository.requireWrite(conn, arena, id, owner, true);
    if (try repository.isDefault(conn, arena, id)) return error.DefaultPlaylistProtected;
    if (std.ascii.eqlIgnoreCase(owner, user)) return error.InvalidInput;
    try repository.removeMember(conn, id, user);
    try conn.commit();
}

pub fn link(db: *database.Database, arena: std.mem.Allocator, id: []const u8, user: []const u8, hash: ?[]const u8) !void {
    const conn = try db.acquire();
    defer conn.release();
    try conn.begin();
    errdefer conn.rollback() catch {};
    try repository.requireWrite(conn, arena, id, user, true);
    if (try repository.isDefault(conn, arena, id)) return error.DefaultPlaylistProtected;
    try repository.setLink(conn, id, hash);
    try conn.commit();
}

fn createRecord(db: *database.Database, arena: std.mem.Allocator, user: []const u8, title: []const u8, description: []const u8, tags: []const u8, visibility: []const u8) ![]const u8 {
    const conn = try db.acquire();
    defer conn.release();
    const result = try repository.create(conn, arena, user, title, description, tags, visibility);
    return result;
}

fn updateRecord(db: *database.Database, arena: std.mem.Allocator, id: []const u8, user: []const u8, title: []const u8, description: []const u8, tags: []const u8, visibility: []const u8) !void {
    const conn = try db.acquire();
    defer conn.release();
    try conn.begin();
    errdefer conn.rollback() catch {};
    try repository.requireWrite(conn, arena, id, user, false);
    if (try repository.isDefault(conn, arena, id)) return error.DefaultPlaylistProtected;
    try repository.update(conn, id, title, description, tags, visibility);
    try conn.commit();
}

pub fn addTrack(db: *database.Database, arena: std.mem.Allocator, id: []const u8, user: []const u8, track_id: []const u8) !void {
    const conn = try db.acquire();
    defer conn.release();
    try conn.begin();
    errdefer conn.rollback() catch {};
    try repository.requireWrite(conn, arena, id, user, false);
    try repository.addTrack(conn, arena, id, user, track_id);
    try conn.commit();
}

pub fn remove(app: *App, arena: std.mem.Allocator, user: []const u8, id: []const u8) !void {
    const conn = try app.db.acquire();
    defer conn.release();
    try conn.begin();
    errdefer conn.rollback() catch {};
    try repository.requireWrite(conn, arena, id, user, true);
    if (try repository.isDefault(conn, arena, id)) return error.DefaultPlaylistProtected;
    if (try repository.remove(conn, arena, id)) |key| {
        _ = try tracks_cleanup_service.enqueue(conn, arena, app.storage.bucket, &.{key}, 0);
    }
    try conn.commit();
}

pub fn removeTrack(db: *database.Database, arena: std.mem.Allocator, id: []const u8, user: []const u8, track_id: []const u8) !void {
    const conn = try db.acquire();
    defer conn.release();
    try conn.begin();
    errdefer conn.rollback() catch {};
    try repository.requireWrite(conn, arena, id, user, false);
    if (try repository.isDefault(conn, arena, id)) {
        try repository.containsTrack(conn, arena, id, track_id);
        try tracks_operations.remove(conn, arena, user, track_id);
    } else {
        try repository.removeTrack(conn, id, track_id);
    }
    try conn.commit();
}
