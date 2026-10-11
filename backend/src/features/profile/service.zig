const std = @import("std");
const App = @import("../../app.zig").App;
const model = @import("model.zig");
const repository = @import("repository.zig");
const operations = @import("operations.zig");
const passwords = @import("../../helpers/passwords.zig");
const users_model = @import("../users/model.zig");
const database = @import("../../infrastructure/database.zig");

/// Возвращает JSON собственного профиля в arena, освобождая соединение перед отправкой.
pub fn read(db: *database.Database, arena: std.mem.Allocator, user: []const u8) ![]const u8 {
    const conn = try db.acquire();
    defer conn.release();

    return repository.read(conn, arena, user);
}

/// Проверяет текущий пароль вне соединения БД; возвращает хеш для повторной проверки под блокировкой.
fn verifyPassword(app: *App, arena: std.mem.Allocator, user: []const u8, password: []const u8) ![]const u8 {
    try users_model.validatePassword(password);

    const hash = blk: {
        const conn = try app.db.acquire();
        defer conn.release();

        break :blk try repository.readCredentials(conn, arena, user);
    };

    try passwords.verify(arena, app.io, hash, password);

    return hash;
}

/// Меняет пароль атомарно и отзывает все сессии, включая текущую.
pub fn changePassword(app: *App, arena: std.mem.Allocator, user: []const u8, input: model.ChangePassword) !void {
    try users_model.validatePassword(input.new_password);
    const previous = try verifyPassword(app, arena, user, input.password);
    const hash = try passwords.hash(arena, app.io, input.new_password);

    const conn = try app.db.acquire();
    defer conn.release();
    try conn.begin();
    errdefer conn.rollback() catch {};

    if (!std.mem.eql(u8, previous, try repository.lockCredentials(conn, arena, user))) return error.Conflict;
    try repository.setPassword(conn, user, hash);
    try conn.commit();
}

/// Удаляет аккаунт и личные треки атомарно; S3 очищается существующим worker после commit.
/// Активная загрузка или подготовка трека отменяет всю операцию без частичного удаления.
pub fn remove(app: *App, arena: std.mem.Allocator, user: []const u8, input: model.Confirmation) !void {
    const previous = try verifyPassword(app, arena, user, input.password);
    const conn = try app.db.acquire();
    defer conn.release();
    try conn.begin();
    errdefer conn.rollback() catch {};

    if (!std.mem.eql(u8, previous, try repository.lockCredentials(conn, arena, user))) return error.Conflict;
    try operations.removeAccount(conn, arena, user, app.storage.bucket);
    try conn.commit();
}
