const std = @import("std");
const App = @import("../../app.zig").App;
const model = @import("model.zig");
const repository = @import("repository.zig");

pub fn create(app: *App, input: model.CreateTrack) ![36]u8 {
    return repository.create(app.db, try model.validateCreate(input));
}

pub fn upload(app: *App, arena: std.mem.Allocator, id: []const u8, mime: []const u8, data: []const u8) ![]const u8 {
    var transaction = try repository.Upload.begin(app.db, id);
    defer transaction.deinit();
    const canonical_id = try std.ascii.allocLowerString(arena, id);
    const key = try std.fmt.allocPrint(arena, "tracks/{s}", .{canonical_id});
    app.storage.put(arena, key, mime, data) catch |err| {
        std.log.err("Track storage upload failed: {s}", .{@errorName(err)});
        if (err == error.StorageTimeout) return error.StorageTimeout;
        return error.StorageUnavailable;
    };
    try transaction.finish(id, app.storage.bucket, key, mime, data.len);
    return key;
}
