const std = @import("std");
const httpz = @import("httpz");
const App = @import("../../app.zig").App;
const model = @import("model.zig");
const repository = @import("repository.zig");
const argon2 = std.crypto.pwhash.argon2;

pub const Session = struct { user_id: []const u8, token: [64]u8 };

pub fn register(app: *App, arena: std.mem.Allocator, raw: model.Credentials) !Session {
    const input = try model.validate(raw);
    var buffer: [256]u8 = undefined;
    const password_hash = try argon2.strHash(input.password, .{ .allocator = arena, .params = .{ .t = 2, .m = 19456, .p = 1 }, .mode = .argon2id }, &buffer, app.storage.io);
    const token = try model.newToken(app.storage.io);
    const hash = model.tokenHash(&token);
    return .{ .user_id = try repository.register(app.db, arena, input.username, password_hash, &hash), .token = token };
}

pub fn login(app: *App, arena: std.mem.Allocator, raw: model.Credentials) !Session {
    const input = try model.validate(raw);
    const stored = try repository.credentials(app.db, arena, input.username);
    // Run the same KDF for absent usernames to avoid a cheap enumeration path.
    var buffer: [256]u8 = undefined;
    const user = stored orelse {
        _ = try argon2.strHash(input.password, .{ .allocator = arena, .params = .{ .t = 2, .m = 19456, .p = 1 }, .mode = .argon2id }, &buffer, app.storage.io);
        return error.Unauthorized;
    };
    argon2.strVerify(user.password_hash, input.password, .{ .allocator = arena }, app.storage.io) catch |err| {
        if (err == error.PasswordVerificationFailed) return error.Unauthorized;
        return err;
    };
    const token = try model.newToken(app.storage.io);
    const token_hash = model.tokenHash(&token);
    try repository.session(app.db, user.id, &token_hash);
    return .{ .user_id = user.id, .token = token };
}

pub fn bearer(req: *httpz.Request) ![]const u8 {
    const header = req.header("authorization") orelse return error.Unauthorized;
    if (header.len < 7 or !std.ascii.eqlIgnoreCase(header[0..7], "Bearer ")) return error.Unauthorized;
    const token = header[7..];
    if (!model.validToken(token)) return error.Unauthorized;
    return token;
}

pub fn optionalUser(app: *App, req: *httpz.Request, arena: std.mem.Allocator) !?[]const u8 {
    if (req.header("authorization") == null and cookieToken(req.header("cookie") orelse "") == null) return null;
    return try requireUser(app, req, arena);
}

pub fn requireUser(app: *App, req: *httpz.Request, arena: std.mem.Allocator) ![]const u8 {
    const hash = model.tokenHash(try requestToken(req));
    return repository.resolve(app.db, arena, &hash);
}

pub fn requestToken(req: *httpz.Request) ![]const u8 {
    if (req.header("authorization") != null) return bearer(req);
    const token = cookieToken(req.header("cookie") orelse "") orelse return error.Unauthorized;
    // Cookie-based writes must originate from this host; Bearer clients remain independent.
    if (req.method != .GET and req.method != .HEAD) {
        if (req.header("origin")) |origin| {
            const delimiter = std.mem.indexOf(u8, origin, "://") orelse return error.Forbidden;
            if (!std.ascii.eqlIgnoreCase(origin[delimiter + 3 ..], req.header("host") orelse "")) return error.Forbidden;
        }
    }
    return token;
}

fn cookieToken(header: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, header, ';');
    while (parts.next()) |part| {
        const value = std.mem.trim(u8, part, " \t");
        if (std.mem.startsWith(u8, value, "musica_session=")) {
            const token = value[15..];
            return if (model.validToken(token)) token else null;
        }
    }
    return null;
}

test "session cookie parsing rejects malformed tokens and permits other cookies" {
    try std.testing.expectEqualStrings("a" ** 64, cookieToken("other=1; musica_session=" ++ "a" ** 64 ++ "; theme=dark").?);
    try std.testing.expect(cookieToken("musica_session=invalid") == null);
    try std.testing.expect(cookieToken("xmusica_session=" ++ "a" ** 64) == null);
}

test "Argon2id hashes verify and reject a wrong password" {
    var buffer: [256]u8 = undefined;
    const hash = try argon2.strHash("test-password-123", .{ .allocator = std.testing.allocator, .params = .{ .t = 2, .m = 19456, .p = 1 }, .mode = .argon2id }, &buffer, std.testing.io);
    try argon2.strVerify(hash, "test-password-123", .{ .allocator = std.testing.allocator }, std.testing.io);
    try std.testing.expectError(error.PasswordVerificationFailed, argon2.strVerify(hash, "wrong-password", .{ .allocator = std.testing.allocator }, std.testing.io));
}
