const std = @import("std");
const App = @import("../../app.zig").App;
const model = @import("model.zig");
const repository = @import("repository.zig");

pub fn create(app: *App, arena: std.mem.Allocator, user: []const u8, input: model.CreateTrack) ![36]u8 {
    return repository.create(app.db, arena, user, app.storage.bucket, try model.validateCreate(input));
}

pub const StorageLocation = struct { bucket: []const u8, key: []const u8 };

pub fn upload(app: *App, arena: std.mem.Allocator, user: []const u8, id: []const u8, mime: []const u8, data: []const u8) !StorageLocation {
    var transaction = try repository.Upload.begin(app.db, arena, id, user);
    defer transaction.deinit();
    var storage = app.storage;
    storage.bucket = transaction.bucket;
    storage.put(arena, transaction.key, mime, data) catch |err| {
        std.log.err("Track storage upload failed: {s}", .{@errorName(err)});
        if (err == error.StorageTimeout) return error.StorageTimeout;
        return error.StorageUnavailable;
    };
    try transaction.finish(id, mime, data.len);
    return .{ .bucket = transaction.bucket, .key = transaction.key };
}
