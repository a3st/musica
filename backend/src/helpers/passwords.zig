const std = @import("std");
const argon2 = std.crypto.pwhash.argon2;

/// Хеширует пароль Argon2id; возвращает собственную копию строки в allocator.
/// Вызывайте до получения соединения БД, чтобы не удерживать его во время вычисления.
pub fn hash(allocator: std.mem.Allocator, io: std.Io, password: []const u8) ![]const u8 {
    var buffer: [256]u8 = undefined;
    const encoded = try argon2.strHash(
        password,
        .{ .allocator = allocator, .params = .{ .t = 2, .m = 19456, .p = 1 }, .mode = .argon2id },
        &buffer,
        io,
    );

    return allocator.dupe(u8, encoded);
}

/// Проверяет пароль вне соединения БД; несовпадение переводит в Unauthorized.
pub fn verify(allocator: std.mem.Allocator, io: std.Io, encoded: []const u8, password: []const u8) !void {
    argon2.strVerify(encoded, password, .{ .allocator = allocator }, io) catch |err| {
        if (err == error.PasswordVerificationFailed) return error.Unauthorized;

        return err;
    };
}

test "password hashes own their memory and reject a wrong password" {
    const allocator = std.testing.allocator;
    const encoded = try hash(allocator, std.testing.io, "test-password-123");
    defer allocator.free(encoded);

    try verify(allocator, std.testing.io, encoded, "test-password-123");
    try std.testing.expectError(error.Unauthorized, verify(allocator, std.testing.io, encoded, "wrong-password"));
}
