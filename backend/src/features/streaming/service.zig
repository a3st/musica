const std = @import("std");
const App = @import("../../app.zig").App;
const model = @import("model.zig");
const repository = @import("repository.zig");

pub const enqueue = repository.enqueue;
pub const read = repository.read;

pub fn object(app: *App, arena: std.mem.Allocator, state: model.State, name: []const u8, max_bytes: usize) ![]const u8 {
    if (state.status != .streamed) return error.HlsNotReady;
    var storage = app.storage;
    storage.bucket = state.bucket orelse return error.DatabaseUnavailable;
    const key = try std.fmt.allocPrint(arena, "{s}/{s}", .{ state.prefix orelse return error.DatabaseUnavailable, name });
    return storage.get(arena, key, max_bytes) catch |err| {
        std.log.err("HLS storage read failed: {s}", .{@errorName(err)});
        if (err == error.StorageTimeout) return error.StorageTimeout;
        return error.StorageUnavailable;
    };
}
