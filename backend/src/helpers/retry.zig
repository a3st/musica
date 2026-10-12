const std = @import("std");

/// Разрешает повторы конкретных сетевых сбоев HTTP; общие ошибки reader/writer не повторяет.
pub fn isTransientHttpError(err: anyerror) bool {
    return switch (err) {
        error.HttpConnectionClosing,
        error.HttpRequestTruncated,
        error.HttpChunkTruncated,
        error.ConnectionResetByPeer,
        error.ConnectionRefused,
        error.ConnectionTimedOut,
        error.Timeout,
        error.BrokenPipe,
        error.NetworkUnreachable,
        error.HostUnreachable,
        => true,
        else => false,
    };
}

/// Ограничивает число попыток и задержки; общий таймаут задаёт вызывающий код.
pub const Policy = struct {
    /// Включает первую попытку, а не только повторы.
    max_attempts: u8 = 3,
    /// Задержки перед повторами; последнее значение используется для остальных попыток.
    delays_ms: []const u32 = &.{ 200, 500 },
    /// Добавляет случайную задержку от нуля до указанного числа миллисекунд.
    jitter_ms: u16 = 50,
};

/// Выполняет операцию с callback подготовки перед каждой попыткой, начиная с номера 1.
/// Ошибка подготовки и отмена завершают вызов сразу; после исчерпания попыток возвращает последнюю ошибку.
/// Контекст и заимствованные данные должны жить до завершения вызова; операция освобождает ресурсы попытки.
pub fn run(
    io: std.Io,
    policy: Policy,
    context: anytype,
    comptime beforeAttempt: anytype,
    comptime operation: anytype,
    comptime shouldRetry: anytype,
) !void {
    if (policy.max_attempts == 0) return error.InvalidRetryPolicy;

    var attempt: u8 = 1;
    while (true) {
        try io.checkCancel();
        try beforeAttempt(context, attempt);

        operation(context) catch |err| {
            if (err == error.Canceled or attempt == policy.max_attempts or !shouldRetry(err))
                return err;

            const base_ms = if (policy.delays_ms.len == 0) 0 else policy.delays_ms[@min(@as(usize, attempt - 1), policy.delays_ms.len - 1)];
            var random: [2]u8 = undefined;
            const jitter: u32 = if (policy.jitter_ms == 0) 0 else blk: {
                io.random(&random);
                break :blk @as(u32, std.mem.readInt(u16, &random, .little)) % (@as(u32, policy.jitter_ms) + 1);
            };
            const delay_ms = @as(u64, base_ms) + jitter;

            std.log.debug("Retry after {s}: attempt {d}/{d}, delay {d}ms", .{
                @errorName(err), attempt + 1, policy.max_attempts, delay_ms,
            });
            if (delay_ms > 0) try std.Io.sleep(io, .fromMilliseconds(@intCast(delay_ms)), .awake);
            attempt += 1;
            continue;
        };

        return;
    }
}

const Fixture = struct {
    writer: *std.Io.Writer,
    attempts: u8 = 0,
    preparations: u8 = 0,
    failures: u8 = 1,
    failure: anyerror = error.ConnectionResetByPeer,
    preparation_failure: bool = false,

    /// Проверяет нумерацию попыток и очищает частичный ответ.
    fn prepare(self: *Fixture, attempt: u8) !void {
        self.preparations += 1;
        try std.testing.expectEqual(self.preparations, attempt);
        if (self.preparation_failure) return error.PreparationFailed;
        self.writer.end = 0;
    }

    /// Имитирует частичную запись при ошибке и полный ответ при успехе.
    fn perform(self: *Fixture) !void {
        self.attempts += 1;
        if (self.attempts <= self.failures) {
            try self.writer.writeAll("partial");
            return self.failure;
        }
        try self.writer.writeAll("complete");
    }

    /// Разрешает тестовую сетевую ошибку и намеренно допускает отмену для проверки защиты helper.
    fn retryable(err: anyerror) bool {
        // Cancellation must still stop the helper when a caller mistakenly allows it.
        return err == error.ConnectionResetByPeer or err == error.Canceled;
    }
};

test "HTTP retry stops on ambiguous IO errors, cancellation and non-network failures" {
    var buffer: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    for ([_]anyerror{
        error.ReadFailed,
        error.WriteFailed,
        error.Canceled,
        error.CatalogUnavailable,
        error.StorageRejected,
        error.OutOfMemory,
    }) |err| {
        var fixture: Fixture = .{ .writer = &writer, .failure = err };
        try std.testing.expectError(err, run(
            std.testing.io,
            .{ .delays_ms = &.{0}, .jitter_ms = 0 },
            &fixture,
            Fixture.prepare,
            Fixture.perform,
            isTransientHttpError,
        ));
        try std.testing.expectEqual(@as(u8, 1), fixture.attempts);
    }
}

test "HTTP retry recovers a connection reset and clears partial response data" {
    var buffer: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var fixture: Fixture = .{ .writer = &writer, .failures = 2 };

    try run(
        std.testing.io,
        .{ .delays_ms = &.{0}, .jitter_ms = 0 },
        &fixture,
        Fixture.prepare,
        Fixture.perform,
        isTransientHttpError,
    );
    try std.testing.expectEqual(@as(u8, 3), fixture.attempts);
    try std.testing.expectEqualStrings("complete", writer.buffered());
}

test "retry resets partial output before each attempt and stops after success" {
    var buffer: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var fixture: Fixture = .{ .writer = &writer };
    try run(
        std.testing.io,
        .{ .delays_ms = &.{0}, .jitter_ms = 0 },
        &fixture,
        Fixture.prepare,
        Fixture.perform,
        Fixture.retryable,
    );
    try std.testing.expectEqualStrings("complete", writer.buffered());
    try std.testing.expectEqual(@as(u8, 2), fixture.attempts);
}

test "retry returns the last error after exactly three attempts" {
    var buffer: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var fixture: Fixture = .{ .writer = &writer, .failures = 10 };
    try std.testing.expectError(error.ConnectionResetByPeer, run(
        std.testing.io,
        .{ .delays_ms = &.{0}, .jitter_ms = 0 },
        &fixture,
        Fixture.prepare,
        Fixture.perform,
        Fixture.retryable,
    ));
    try std.testing.expectEqual(@as(u8, 3), fixture.attempts);
}

test "retry stops on permanent errors, cancellation and preparation failures" {
    var buffer: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for ([_]anyerror{ error.AccessDenied, error.Canceled }) |err| {
        var fixture: Fixture = .{ .writer = &writer, .failure = err };
        try std.testing.expectError(err, run(
            std.testing.io,
            .{},
            &fixture,
            Fixture.prepare,
            Fixture.perform,
            Fixture.retryable,
        ));
        try std.testing.expectEqual(@as(u8, 1), fixture.attempts);
    }

    var fixture: Fixture = .{ .writer = &writer, .preparation_failure = true };
    try std.testing.expectError(error.PreparationFailed, run(
        std.testing.io,
        .{},
        &fixture,
        Fixture.prepare,
        Fixture.perform,
        Fixture.retryable,
    ));
    try std.testing.expectEqual(@as(u8, 0), fixture.attempts);
}
