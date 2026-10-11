const std = @import("std");
const httpz = @import("httpz");
const App = @import("../../app.zig").App;
const model = @import("model.zig");
const repository = @import("repository.zig");
const database = @import("../../infrastructure/database.zig");
const passwords = @import("../../helpers/passwords.zig");
const users_model = @import("../users/model.zig");
const users_operations = @import("../users/operations.zig");

/// Результат создания сессии; user_id хранится в arena, токен возвращается по значению.
pub const Session = struct {
    user_id: []const u8,
    token: [64]u8,
};

/// Создаёт пользователя и сессию атомарно; пароль хешируется до получения соединения БД.
pub fn register(app: *App, arena: std.mem.Allocator, raw: model.Credentials) !Session {
    const input = try users_operations.prepareCreate(arena, app.io, .{
        .username = raw.username,
        .password = raw.password,
    });

    const token = try model.generateToken(app.storage.io);
    const hash = model.tokenHash(&token);

    return .{ .user_id = try registerRecord(&app.db, arena, input, &hash), .token = token };
}

/// Проверяет пароль вне соединения БД и создаёт сессию; неизвестный пользователь также проходит вычисление Argon2id.
pub fn login(app: *App, arena: std.mem.Allocator, raw: model.Credentials) !Session {
    const input = try model.validateCredentials(raw);
    const stored = try findCredentials(&app.db, arena, input.username);
    // Неизвестное имя также проходит Argon2id, чтобы не раскрывать наличие учётки по времени ответа.
    const user = stored orelse {
        _ = try passwords.hash(arena, app.io, input.password);

        return error.Unauthorized;
    };
    try passwords.verify(arena, app.io, user.password_hash, input.password);

    const token = try model.generateToken(app.storage.io);
    const token_hash = model.tokenHash(&token);
    try createSession(&app.db, user.id, &token_hash);

    return .{ .user_id = user.id, .token = token };
}

/// Читает и проверяет Bearer-токен из Authorization; отсутствие или неверный формат — Unauthorized.
pub fn readBearerToken(req: *httpz.Request) ![]const u8 {
    const header = req.header("authorization") orelse return error.Unauthorized;
    if (header.len < 7 or !std.ascii.eqlIgnoreCase(header[0..7], "Bearer ")) return error.Unauthorized;

    const token = header[7..];
    if (!model.isValidToken(token)) return error.Unauthorized;

    return token;
}

/// Возвращает null без Authorization и корректной cookie; найденный токен проверяет через requireUser.
pub fn optionalUser(app: *App, req: *httpz.Request, arena: std.mem.Allocator) !?[]const u8 {
    if (req.header("authorization") == null and readCookieToken(req.header("cookie") orelse "") == null) return null;

    return try requireUser(app, req, arena);
}

/// Проверяет действующую сессию запроса и возвращает ID пользователя в arena.
pub fn requireUser(app: *App, req: *httpz.Request, arena: std.mem.Allocator) ![]const u8 {
    const hash = model.tokenHash(try readRequestToken(req));

    return resolveSession(&app.db, arena, &hash);
}

/// Выбирает Authorization перед cookie; для записи через cookie проверяет Origin, если он передан.
pub fn readRequestToken(req: *httpz.Request) ![]const u8 {
    if (req.header("authorization") != null) return readBearerToken(req);

    const token = readCookieToken(req.header("cookie") orelse "") orelse return error.Unauthorized;
    // Cookie-based writes must originate from this host; Bearer clients remain independent.
    if (req.method != .GET and req.method != .HEAD) {
        if (req.header("origin")) |origin| {
            const delimiter = std.mem.indexOf(u8, origin, "://") orelse return error.Forbidden;
            if (!std.ascii.eqlIgnoreCase(origin[delimiter + 3 ..], req.header("host") orelse "")) return error.Forbidden;
        }
    }

    return token;
}

/// Читает проверенный токен musica_session из Cookie; возвращает срез заголовка или null.
fn readCookieToken(header: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, header, ';');
    while (parts.next()) |part| {
        const value = std.mem.trim(u8, part, " \t");
        if (std.mem.startsWith(u8, value, "musica_session=")) {
            const token = value[15..];

            return if (model.isValidToken(token)) token else null;
        }
    }

    return null;
}

test "session cookie parsing rejects malformed tokens and permits other cookies" {
    try std.testing.expectEqualStrings("a" ** 64, readCookieToken("other=1; musica_session=" ++ "a" ** 64 ++ "; theme=dark").?);
    try std.testing.expect(readCookieToken("musica_session=invalid") == null);
    try std.testing.expect(readCookieToken("xmusica_session=" ++ "a" ** 64) == null);
}

/// В одной транзакции создаёт пользователя и сессию; возвращает ID пользователя в arena.
fn registerRecord(
    db: *database.Database,
    arena: std.mem.Allocator,
    input: users_model.PreparedUser,
    token_hash: []const u8,
) ![]const u8 {
    const conn = try db.acquire();
    defer conn.release();

    try conn.begin();
    errdefer conn.rollback() catch {};

    const result = try users_operations.create(conn, arena, input);
    try repository.createSession(conn, result, token_hash);

    try conn.commit();

    return result;
}

/// Возвращает данные проверки пароля в arena или null, освобождая соединение перед хешированием.
fn findCredentials(
    db: *database.Database,
    arena: std.mem.Allocator,
    username: []const u8,
) !?model.StoredCredentials {
    const conn = try db.acquire();
    defer conn.release();

    const result = try repository.findCredentials(conn, arena, username);

    return result;
}

/// Создаёт сессию по хешу токена, самостоятельно получая и освобождая соединение.
fn createSession(db: *database.Database, user_id: []const u8, hash: []const u8) !void {
    const conn = try db.acquire();
    defer conn.release();

    try repository.createSession(conn, user_id, hash);
}

/// Возвращает ID пользователя действующей сессии по хешу токена; иначе Unauthorized.
fn resolveSession(db: *database.Database, arena: std.mem.Allocator, hash: []const u8) ![]const u8 {
    const conn = try db.acquire();
    defer conn.release();

    const result = try repository.resolveSession(conn, arena, hash);

    return result;
}

/// Удаляет сессию по хешу токена.
pub fn logout(db: *database.Database, hash: []const u8) !void {
    const conn = try db.acquire();
    defer conn.release();

    try repository.removeSession(conn, hash);
}
