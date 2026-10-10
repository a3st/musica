const std = @import("std");
const pg = @import("pg");

/// Настройки подключения; строки из load ссылаются на переданную карту окружения.
pub const Settings = struct {
    host: []const u8,
    port: u16,
    name: []const u8,
    username: []const u8,
    password: []const u8,

    /// Читает DB-переменные окружения и проверяет настройки; DB_PASSWORD обязателен.
    pub fn load(env: *const std.process.Environ.Map) !Settings {
        const password = env.get("DB_PASSWORD") orelse {
            std.log.err("Missing environment variable: DB_PASSWORD", .{});
            return error.MissingConfiguration;
        };

        const settings: Settings = .{
            .host = env.get("DB_HOST") orelse "127.0.0.1",
            .port = try std.fmt.parseInt(u16, env.get("DB_PORT") orelse "5432", 10),
            .name = env.get("DB_NAME") orelse "musica",
            .username = env.get("DB_USER") orelse "musica",
            .password = password,
        };

        if (settings.port == 0 or settings.host.len == 0 or settings.name.len == 0 or
            settings.username.len == 0 or settings.password.len == 0)
            return error.InvalidConfiguration;

        return settings;
    }
};

/// Владеет пулом соединений. Не освобождайте копии структуры как независимые пулы.
pub const Database = struct {
    pool: *pg.Pool,

    /// Создаёт пул из четырёх соединений; ошибки драйвера переводит в DatabaseUnavailable.
    pub fn init(io: std.Io, allocator: std.mem.Allocator, config: Settings) !Database {
        const pool = pg.Pool.init(io, allocator, .{
            .size = 4,
            .timeout = 5000,
            .connect = .{ .host = config.host, .port = config.port },
            .auth = .{
                .username = config.username,
                .password = config.password,
                .database = config.name,
                .application_name = "musica",
                .timeout = 5000,
            },
        }) catch |err| {
            std.log.err("Database initialization failed: {s}", .{@errorName(err)});
            return error.DatabaseUnavailable;
        };

        return .{ .pool = pool };
    }

    /// Берёт соединение из пула; вызывающий код должен вернуть его через release.
    pub fn acquire(self: *Database) !*Connection {
        return @ptrCast(self.pool.acquire() catch return error.DatabaseUnavailable);
    }

    /// Освобождает пул после возврата всех соединений; структура больше не пригодна к использованию.
    pub fn deinit(self: *Database) void {
        self.pool.deinit();
        self.* = undefined;
    }
};

/// Соединение, полученное из Database; скрывает тип и API драйвера PostgreSQL.
pub const Connection = opaque {
    /// Возвращает внутреннее соединение драйвера для реализации этого модуля.
    fn driver(self: *Connection) *pg.Conn {
        return @ptrCast(@alignCast(self));
    }

    /// Возвращает соединение в пул; после вызова использовать его нельзя.
    /// Транзакцию следует завершить через commit или rollback до возврата.
    pub fn release(self: *Connection) void {
        self.driver().release();
    }

    /// Начинает транзакцию на текущем соединении; завершение выполняет вызывающий сервис.
    pub fn begin(self: *Connection) !void {
        self.driver().begin() catch |err| return mapError(self.driver(), err);
    }

    /// Подтверждает текущую транзакцию и освобождает её блокировки.
    pub fn commit(self: *Connection) !void {
        self.driver().commit() catch |err| return mapError(self.driver(), err);
    }

    /// Откатывает текущую транзакцию и освобождает её блокировки.
    pub fn rollback(self: *Connection) !void {
        self.driver().rollback() catch |err| return mapError(self.driver(), err);
    }

    /// Выполняет параметризованный запрос и копирует первый текстовый столбец первой строки в arena.
    /// Возвращает null при отсутствии строки; таймаут запроса — 10 секунд.
    pub fn queryText(
        self: *Connection,
        arena: std.mem.Allocator,
        query: []const u8,
        values: anytype,
    ) !?[]const u8 {
        const conn = self.driver();
        var row = (conn.rowOpts(query, values, .{ .timeout = 10000 }) catch |err| return mapError(conn, err)) orelse return null;
        var finished = false;
        defer if (!finished) row.deinit() catch {};

        // The driver owns response memory until QueryRow.deinit; copy before releasing it.
        const value = try arena.dupe(u8, row.get([]const u8, 0) catch |err| return mapError(conn, err));
        finished = true;
        row.deinit() catch |err| return mapError(conn, err);

        return value;
    }

    /// Выполняет параметризованную команду и возвращает число затронутых строк, либо 0 без счётчика.
    /// Таймаут команды — 10 секунд; ошибки драйвера переводятся в ошибки приложения.
    pub fn exec(self: *Connection, query: []const u8, values: anytype) !i64 {
        const conn = self.driver();

        return (conn.execOpts(query, values, .{ .timeout = 10000 }) catch |err| return mapError(conn, err)) orelse 0;
    }
};

/// Переводит SQLSTATE в ошибки приложения; неизвестные ошибки — в DatabaseUnavailable.
/// Логирует код или тип ошибки без SQL, параметров и текста ответа сервера.
fn mapError(conn: *pg.Conn, err: anyerror) anyerror {
    if (err == error.PG) {
        if (conn.err) |details| {
            if (std.mem.eql(u8, details.code, "23505")) return error.Conflict;
            if (std.mem.eql(u8, details.code, "23503")) return error.ReferenceNotFound;
            if (std.mem.eql(u8, details.code, "23514")) return error.InvalidInput;
            if (std.mem.eql(u8, details.code, "55P03")) return error.LockUnavailable;

            // Never log SQL text, parameters, or the server's free-form message.
            std.log.err("PostgreSQL operation failed: SQLSTATE {s}", .{details.code});
            return error.DatabaseUnavailable;
        }
    }

    std.log.err("PostgreSQL operation failed: {s}", .{@errorName(err)});
    return error.DatabaseUnavailable;
}
