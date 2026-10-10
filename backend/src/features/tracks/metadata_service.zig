const std = @import("std");
const App = @import("../../app.zig").App;
const database = @import("../../infrastructure/database.zig");
const jobs_repository = @import("../../infrastructure/jobs/repository.zig");
const model = @import("model.zig");
const repository = @import("repository.zig");
const cleanup_service = @import("cleanup_service.zig");

/// Арендует извлечение метаданных на 60 секунд; некорректный payload завершает без повторов.
pub fn claim(db: *database.Database, arena: std.mem.Allocator) !?model.MetadataTask {
    const conn = try db.acquire();
    defer conn.release();

    const job = (try jobs_repository.claim(conn, arena, model.metadata_job_kind, 60)) orelse return null;
    const payload = job.decodePayload(model.MetadataPayload, arena) catch |err| {
        try jobs_repository.fail(conn, job, false, 0);

        return err;
    };

    return .{ .job = job, .payload = payload };
}

/// Продлевает действующую аренду обработки на 60 секунд по часам БД.
pub fn heartbeat(db: *database.Database, task: model.MetadataTask) !void {
    const conn = try db.acquire();
    defer conn.release();

    try jobs_repository.heartbeat(conn, task.job, 60);
}

/// Планирует очистку новой обложки при потере аренды, отмене или ошибке публикации.
/// Задержка покрывает общий таймаут обработки и запас на завершение запросов S3.
pub fn reserveArtwork(
    app: *App,
    arena: std.mem.Allocator,
    task: model.MetadataTask,
    key: []const u8,
) ![]const u8 {
    const conn = try app.db.acquire();
    defer conn.release();

    try conn.begin();
    errdefer conn.rollback() catch {};

    try repository.lock(conn, arena, task.payload.track_id);
    try jobs_repository.heartbeat(conn, task.job, 60);

    const reservation = try cleanup_service.enqueue(
        conn,
        arena,
        task.payload.bucket,
        &.{key},
        app.metadata_timeout_seconds + 120,
    );

    try conn.commit();

    return reservation;
}

/// Атомарно сохраняет метаданные исходника и завершает задачу; устаревшая попытка ничего не публикует.
pub fn publish(
    app: *App,
    arena: std.mem.Allocator,
    task: model.MetadataTask,
    metadata: model.Metadata,
    reservation: ?[]const u8,
) !void {
    const conn = try app.db.acquire();
    defer conn.release();

    try conn.begin();
    errdefer conn.rollback() catch {};

    try repository.lock(conn, arena, task.payload.track_id);
    try jobs_repository.complete(conn, task.job);
    try repository.setMetadata(conn, task.payload, metadata);
    if (reservation) |id| try cleanup_service.cancelScheduledCleanup(conn, id);

    try conn.commit();
}

/// Фиксирует ошибку обработки; разрешённые повторы выполняются через 30 секунд.
pub fn fail(db: *database.Database, task: model.MetadataTask, retry: bool) !void {
    const conn = try db.acquire();
    defer conn.release();

    jobs_repository.fail(conn, task.job, retry, 30) catch |err| if (err != error.LeaseLost) return err;
}
