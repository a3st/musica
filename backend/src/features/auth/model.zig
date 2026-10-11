const std = @import("std");
const users_model = @import("../users/model.zig");

/// Учётные данные регистрации или входа; административное создание использует users_model.CreateUser.
pub const Credentials = struct {
    username: []const u8,
    password: []const u8,
};

/// Данные пользователя для проверки пароля; хеш не предназначен для ответа API.
pub const StoredCredentials = struct {
    id: []const u8,
    password_hash: []const u8,
};

/// Проверяет имя пользователя и пароль без изменения данных; иначе InvalidCredentials.
pub fn validateCredentials(input: Credentials) !Credentials {
    _ = try users_model.validateCreate(.{ .username = input.username, .password = input.password });

    return input;
}

/// Проверяет токен из 64 строчных шестнадцатеричных символов.
pub fn isValidToken(token: []const u8) bool {
    if (token.len != 64) return false;

    for (token) |c| {
        if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    }

    return true;
}

/// Возвращает SHA-256 токена в hex-формате для хранения и поиска сессии.
pub fn tokenHash(token: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});

    return std.fmt.bytesToHex(digest, .lower);
}

/// Генерирует криптографически случайный токен из 32 байт в hex-формате.
pub fn generateToken(io: std.Io) ![64]u8 {
    var bytes: [32]u8 = undefined;
    try io.randomSecure(&bytes);

    return std.fmt.bytesToHex(bytes, .lower);
}

test "credentials and bearer tokens reject malformed values" {
    _ = try validateCredentials(.{ .username = "user_1", .password = "long-password-123" });

    try std.testing.expectError(error.InvalidCredentials, validateCredentials(.{ .username = "User", .password = "long-password-123" }));
    try std.testing.expectError(error.InvalidCredentials, validateCredentials(.{ .username = "user", .password = "short" }));
    try std.testing.expect(isValidToken("a" ** 64));
    try std.testing.expect(!isValidToken("A" ** 64));
    try std.testing.expect(!isValidToken("a" ** 63));

    const digest = tokenHash("a" ** 64);

    try std.testing.expect(!std.mem.eql(u8, &digest, "a" ** 64));
}
