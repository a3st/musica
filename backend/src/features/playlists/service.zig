const std = @import("std");
const App = @import("../../app.zig").App;
const model = @import("model.zig");
const repository = @import("repository.zig");
const tokens = @import("../auth/model.zig");

pub fn create(app: *App, arena: std.mem.Allocator, user: []const u8, raw: model.CreatePlaylist) ![]const u8 {
    const input = try model.validateCreate(raw);
    const tags = try std.json.Stringify.valueAlloc(arena, input.tags, .{});
    return repository.create(app.db, arena, user, input.title, input.description, tags, @tagName(input.visibility));
}

pub fn update(app: *App, arena: std.mem.Allocator, user: []const u8, id: []const u8, raw: model.CreatePlaylist) !void {
    const input = try model.validateCreate(raw);
    const tags = try std.json.Stringify.valueAlloc(arena, input.tags, .{});
    try repository.update(app.db, arena, id, user, input.title, input.description, tags, @tagName(input.visibility));
}

pub fn createLink(app: *App, arena: std.mem.Allocator, user: []const u8, id: []const u8) ![64]u8 {
    const token = try tokens.newToken(app.storage.io);
    const hash = tokens.tokenHash(&token);
    try repository.link(app.db, arena, id, user, &hash);
    return token;
}

pub fn image(app: *App, arena: std.mem.Allocator, user: []const u8, id: []const u8, mime: []const u8, data: []const u8) ![]const u8 {
    if (!validImage(mime, data)) return error.InvalidInput;
    var transaction = try repository.ImageUpload.begin(app.db, arena, id, user);
    defer transaction.deinit();
    const token = try tokens.newToken(app.storage.io);
    const key = try std.fmt.allocPrint(arena, "playlists/{s}/{s}", .{ id, &token });
    app.storage.put(arena, key, mime, data) catch |err| {
        std.log.err("Playlist image storage upload failed: {s}", .{@errorName(err)});
        if (err == error.StorageTimeout) return error.StorageTimeout;
        return error.StorageUnavailable;
    };
    try transaction.finish(id, key);
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
