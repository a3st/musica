const std = @import("std");
const App = @import("../../app.zig").App;
const repository = @import("repository.zig");
const operations = @import("operations.zig");

/// Обеспечивает наличие сервисной учётки и создаёт стартового администратора, если он ещё не существует.
/// Учётные данные администратора должны быть заданы вместе; хеширование выполняется вне соединения БД.
pub fn bootstrap(app: *App, arena: std.mem.Allocator, username: ?[]const u8, password: ?[]const u8) !void {
    {
        const conn = try app.db.acquire();
        defer conn.release();

        _ = try repository.ensureSystem(conn, arena);
    }

    if (username) |name| {
        const input = try operations.prepareCreate(arena, app.io, .{
            .username = name,
            .password = password.?,
        });

        const conn = try app.db.acquire();
        defer conn.release();

        try conn.begin();
        errdefer conn.rollback() catch {};

        try repository.bootstrapAdmin(conn, arena, input.username, input.password_hash);

        try conn.commit();
    }
}
