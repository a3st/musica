const std = @import("std");
const database = @import("../../infrastructure/database.zig");
const model = @import("model.zig");
const jobs_repository = @import("../../infrastructure/jobs/repository.zig");

/// Создаёт задачу удаления ключей из одного бакета с задержкой в секундах и без лимита повторов.
/// Принимает соединение вызывающего кода; ID задачи выделяется в arena.
pub fn enqueue(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    bucket: []const u8,
    keys: []const []const u8,
    delay: u32,
) ![]const u8 {
    const task = try jobs_repository.enqueueNew(
        conn,
        arena,
        model.cleanup_job_kind,
        model.CleanupPayload{ .bucket = bucket, .keys = keys },
        delay,
        null,
    );

    return task.id;
}

/// Планирует удаление нового объекта через 120 секунд на случай неуспешной публикации.
pub fn scheduleFallbackCleanup(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    bucket: []const u8,
    key: []const u8,
) ![]const u8 {
    return enqueue(conn, arena, bucket, &.{key}, 120);
}

/// Отменяет запланированное удаление успешно опубликованного объекта.
/// Если задачу уже нельзя отменить, переводит LeaseLost в UploadInProgress.
pub fn cancelScheduledCleanup(conn: *database.Connection, id: []const u8) !void {
    jobs_repository.cancelScheduled(conn, id) catch |err| {
        if (err == error.LeaseLost) return error.UploadInProgress;

        return err;
    };
}

/// Арендует задачу очистки на 120 секунд и разбирает payload в arena; null, если работы нет.
/// Некорректный payload помечает failed без повторов.
pub fn claim(db: *database.Database, arena: std.mem.Allocator) !?model.CleanupTask {
    const conn = try db.acquire();
    defer conn.release();

    const job = (try jobs_repository.claim(conn, arena, model.cleanup_job_kind, 120)) orelse return null;

    const payload = job.decodePayload(model.CleanupPayload, arena) catch |err| {
        try jobs_repository.fail(conn, job, false, 0);

        return err;
    };

    return .{ .job = job, .payload = payload };
}

/// Возвращает текущую задачу очистки в очередь с задержкой 30 секунд при действующей аренде.
pub fn retry(db: *database.Database, task: model.CleanupTask) !void {
    const conn = try db.acquire();
    defer conn.release();

    try jobs_repository.fail(conn, task.job, true, 30);
}

/// Удаляет успешно выполненную задачу очистки при совпадении попытки и действующей аренде.
pub fn finish(db: *database.Database, task: model.CleanupTask) !void {
    const conn = try db.acquire();
    defer conn.release();

    try jobs_repository.removeLeased(conn, task.job);
}

/// Продлевает действующую аренду задачи очистки на 120 секунд по часам БД.
pub fn heartbeat(db: *database.Database, task: model.CleanupTask) !void {
    const conn = try db.acquire();
    defer conn.release();

    try jobs_repository.heartbeat(conn, task.job, 120);
}
