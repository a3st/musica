const std = @import("std");

/// Тип учётки; роль администратора и доступ к плейлистам определяются отдельно.
pub const Kind = enum {
    user,
    system,
};

/// Данные создания обычной учётки; создание сессии и полномочия задаёт вызывающий сценарий.
pub const CreateUser = struct {
    username: []const u8,
    password: []const u8,
};

/// Проверенные данные и готовый хеш; строки живут до освобождения arena подготовки.
pub const PreparedUser = struct {
    username: []const u8,
    password_hash: []const u8,
};

/// Проверяет длину и UTF-8 пароля без обрезания пробелов.
pub fn validatePassword(password: []const u8) !void {
    if (password.len < 12 or password.len > 1024 or !std.unicode.utf8ValidateSlice(password)) {
        return error.InvalidCredentials;
    }
}

/// Проверяет имя и пароль обычного пользователя, сохраняя исходные значения.
pub fn validateCreate(input: CreateUser) !CreateUser {
    if (input.username.len < 3 or input.username.len > 64) return error.InvalidCredentials;

    for (input.username) |character| {
        if (!(std.ascii.isLower(character) or std.ascii.isDigit(character) or character == '_')) {
            return error.InvalidCredentials;
        }
    }

    try validatePassword(input.password);

    return input;
}

test "user credentials reject malformed input and preserve password whitespace" {
    _ = try validateCreate(.{ .username = "user_1", .password = " long-password " });
    try std.testing.expectError(error.InvalidCredentials, validateCreate(.{ .username = "User", .password = "long-password-123" }));
    try std.testing.expectError(error.InvalidCredentials, validatePassword("short"));
    try std.testing.expectError(error.InvalidCredentials, validatePassword("password-long\xff"));
}
