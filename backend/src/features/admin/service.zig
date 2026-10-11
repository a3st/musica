const std = @import("std");
const App = @import("../../app.zig").App;
const model = @import("model.zig");
const repository = @import("repository.zig");
const users_repository = @import("../users/repository.zig");
const web_int_repository = @import("../web_int/repository.zig");
const tracks_operations = @import("../tracks/operations.zig");
const users_model = @import("../users/model.zig");
const users_operations = @import("../users/operations.zig");
const profile_repository = @import("../profile/repository.zig");
const profile_operations = @import("../profile/operations.zig");

/// Возвращает список обычных пользователей только администратору.
pub fn listUsers(app: *App, arena: std.mem.Allocator, user: []const u8) ![]const u8 {
    const conn = try app.db.acquire();
    defer conn.release();
    try users_repository.requireAdmin(conn, arena, user);

    return repository.listUsers(conn, arena);
}

/// Проверяет административную роль и создаёт обычного пользователя без выдачи сессии.
/// Хеширование выполняет до транзакции; перед записью повторно проверяет полномочия.
pub fn createUser(app: *App, arena: std.mem.Allocator, user: []const u8, raw: users_model.CreateUser) ![]const u8 {
    {
        const conn = try app.db.acquire();
        defer conn.release();

        try users_repository.requireAdmin(conn, arena, user);
    }

    const input = try users_operations.prepareCreate(arena, app.io, raw);
    const conn = try app.db.acquire();
    defer conn.release();

    try conn.begin();
    errdefer conn.rollback() catch {};

    try users_repository.requireAdmin(conn, arena, user);
    const id = try users_operations.create(conn, arena, input);

    try conn.commit();

    return id;
}

/// Удаляет другую обычную учётку и личные файлы; системная учётка недоступна.
/// Самостоятельное удаление администратора выполняется через profile с подтверждением паролем.
pub fn removeUser(app: *App, arena: std.mem.Allocator, user: []const u8, target: []const u8) !void {
    if (std.ascii.eqlIgnoreCase(user, target)) return error.Forbidden;
    const conn = try app.db.acquire();
    defer conn.release();
    try conn.begin();
    errdefer conn.rollback() catch {};
    try users_repository.requireAdmin(conn, arena, user);
    _ = try profile_repository.lockCredentials(conn, arena, target);
    try profile_operations.removeAccount(conn, arena, target, app.storage.bucket);
    try conn.commit();
}

/// Проверяет роль на сервере и возвращает статистику исходников.
pub fn readStorage(app: *App, arena: std.mem.Allocator, user: []const u8) !model.Storage {
    const conn = try app.db.acquire();
    defer conn.release();
    try users_repository.requireAdmin(conn, arena, user);

    return repository.readStorage(conn, arena);
}

/// Удаляет до 20 orphaned-треков без ожидания retention; активные операции пропускает.
/// Проверяет привязки под блокировкой, файлы удаляет существующий S3 worker.
pub fn cleanupOrphaned(app: *App, arena: std.mem.Allocator, user: []const u8) !model.Cleanup {
    const conn = try app.db.acquire();
    defer conn.release();
    try users_repository.requireAdmin(conn, arena, user);
    const ids = try web_int_repository.listCleanupCandidates(conn, arena, 0);
    var result: model.Cleanup = .{ .removed = 0, .skipped = 0 };

    for (ids) |id| {
        try conn.begin();
        errdefer conn.rollback() catch {};
        try users_repository.requireAdmin(conn, arena, user);

        if (try web_int_repository.lockForCleanup(conn, arena, id, 0)) |owner| {
            tracks_operations.remove(conn, arena, owner, id) catch |err| {
                try conn.rollback();
                if (err == error.UploadInProgress or err == error.TrackPreparationInProgress) {
                    result.skipped += 1;
                    continue;
                }
                return err;
            };
            result.removed += 1;
        } else {
            result.skipped += 1;
        }

        try conn.commit();
    }

    return result;
}
