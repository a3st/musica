const std = @import("std");
const App = @import("../../app.zig").App;
const database = @import("../../infrastructure/database.zig");
const jobs_repository = @import("../../infrastructure/jobs/repository.zig");
const users_repository = @import("../users/repository.zig");
const model = @import("model.zig");
const repository = @import("repository.zig");

/// Запрещает импорт при отключении Web или Spotify до создания треков и задач.
pub fn requireEnabled(app: *const App) !void {
    if (!app.imports_enabled) return error.ImportsDisabled;
}

/// Переиспользует или создаёт общий трек у сервисной учётки и ставит загрузку в очередь.
/// Принимает соединение с транзакцией вызывающего кода; ID трека выделяется в arena.
pub fn enqueueTrack(
    app: *App,
    conn: *database.Connection,
    arena: std.mem.Allocator,
    track: model.Track,
    source: ?model.Source,
) ![]const u8 {
    try requireEnabled(app);

    const input = try model.validateTrack(track);
    const owner = try users_repository.ensureSystem(conn, arena);
    const id = try repository.getOrCreateSharedTrack(conn, arena, owner, app.storage.bucket, input, source);

    _ = try jobs_repository.enqueue(
        conn,
        arena,
        model.download_job_kind,
        id,
        model.Payload{ .user_id = owner, .track_id = id, .track = input },
        0,
        3,
    );

    return id;
}

/// Арендует задачу скачивания на 120 секунд и разбирает payload в arena; null, если работы нет.
/// Некорректный payload помечает failed без повторов.
pub fn claim(db: *database.Database, arena: std.mem.Allocator) !?model.Task {
    const conn = try db.acquire();
    defer conn.release();

    const job = (try jobs_repository.claim(conn, arena, model.download_job_kind, 120)) orelse return null;

    const payload = job.decodePayload(model.Payload, arena) catch |err| {
        try jobs_repository.fail(conn, job, false, 0);

        return err;
    };

    return .{ .job = job, .payload = payload };
}

/// Продлевает действующую аренду скачивания на 120 секунд по часам БД.
pub fn heartbeat(db: *database.Database, task: model.Task) !void {
    const conn = try db.acquire();
    defer conn.release();

    try jobs_repository.heartbeat(conn, task.job, 120);
}

/// Помечает задачу скачивания завершённой при совпадении попытки и действующей аренде.
pub fn complete(db: *database.Database, task: model.Task) !void {
    const conn = try db.acquire();
    defer conn.release();

    try jobs_repository.complete(conn, task.job);
}

/// Фиксирует ошибку или планирует разрешённый повтор через 30 секунд; потерянную аренду игнорирует.
pub fn fail(db: *database.Database, task: model.Task, retryable: bool) !void {
    const conn = try db.acquire();
    defer conn.release();

    jobs_repository.fail(conn, task.job, retryable, 30) catch |err| if (err != error.LeaseLost) return err;
}

test "disabled imports reject track creation before accessing the database" {
    var app: App = undefined;
    app.imports_enabled = false;

    try std.testing.expectError(error.ImportsDisabled, enqueueTrack(
        &app,
        undefined,
        std.testing.allocator,
        .{ .title = "Song", .artist = "Artist" },
        null,
    ));
}
