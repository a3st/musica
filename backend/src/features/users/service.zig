const std = @import("std");
const App = @import("../../app.zig").App;
const repository = @import("repository.zig");
const auth_model = @import("../auth/model.zig");
const auth_repository = @import("../auth/repository.zig");

pub fn bootstrap(app: *App, arena: std.mem.Allocator, username: ?[]const u8, password: ?[]const u8) !void {
    {
        const conn = try app.db.acquire();
        defer conn.release();
        _ = try repository.ensureSystem(conn, arena);
    }
    if (username) |name| {
        const input = try auth_model.validate(.{ .username = name, .password = password.? });
        var buffer: [256]u8 = undefined;
        const hash = try std.crypto.pwhash.argon2.strHash(input.password, .{ .allocator = arena, .params = .{ .t = 2, .m = 19456, .p = 1 }, .mode = .argon2id }, &buffer, app.storage.io);
        const conn = try app.db.acquire();
        defer conn.release();
        try conn.begin();
        errdefer conn.rollback() catch {};
        try repository.bootstrapAdmin(conn, arena, input.username, hash);
        try conn.commit();
    }
}

pub fn create(app: *App, arena: std.mem.Allocator, admin: []const u8, raw: auth_model.Credentials) ![]const u8 {
    {
        const conn = try app.db.acquire();
        defer conn.release();
        try repository.requireAdmin(conn, arena, admin);
    }
    const input = try auth_model.validate(raw);
    var buffer: [256]u8 = undefined;
    const hash = try std.crypto.pwhash.argon2.strHash(input.password, .{ .allocator = arena, .params = .{ .t = 2, .m = 19456, .p = 1 }, .mode = .argon2id }, &buffer, app.storage.io);
    const conn = try app.db.acquire();
    defer conn.release();
    return auth_repository.createUser(conn, arena, input.username, hash);
}
