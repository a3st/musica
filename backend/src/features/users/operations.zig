const std = @import("std");
const database = @import("../../infrastructure/database.zig");
const passwords = @import("../../helpers/passwords.zig");
const model = @import("model.zig");
const repository = @import("repository.zig");

/// Валидирует данные и хеширует пароль до получения соединения БД; строки результата принадлежат arena.
pub fn prepareCreate(arena: std.mem.Allocator, io: std.Io, raw: model.CreateUser) !model.PreparedUser {
    const input = try model.validateCreate(raw);

    return .{
        .username = try arena.dupe(u8, input.username),
        .password_hash = try passwords.hash(arena, io, input.password),
    };
}

/// Создаёт обычного пользователя с готовым хешем и возвращает ID в arena.
/// Полномочия, сессии и транзакцией управляет вызывающий сервис.
pub fn create(conn: *database.Connection, arena: std.mem.Allocator, input: model.PreparedUser) ![]const u8 {
    return repository.create(conn, arena, input.username, input.password_hash);
}
