const std = @import("std");
const App = @import("../../app.zig").App;
const database = @import("../../infrastructure/database.zig");
const model = @import("model.zig");
const repository = @import("repository.zig");
const jobs_repository = @import("../../infrastructure/jobs/repository.zig");
const tracks_model = @import("../tracks/model.zig");
const playlists_repository = @import("../playlists/repository.zig");
const users_repository = @import("../users/repository.zig");

/// Ищет песни в iTunes; общий кеш живёт десять минут, соединение БД не удерживается во время HTTP.
pub fn search(app: *App, arena: std.mem.Allocator, term: []const u8) ![]const model.SearchTrack {
    const query = try model.validateSearch(term);
    const key = try std.fmt.allocPrint(arena, "itunes:search:US:{s}", .{query});
    if (try readSearchCache(app, arena, key)) |body| {
        return (try std.json.parseFromSlice([]const model.SearchTrack, arena, body, .{ .allocate = .alloc_always })).value;
    }

    const tracks = try app.catalog.search(arena, query);
    const body = try std.json.Stringify.valueAlloc(arena, tracks, .{});
    const conn = try app.db.acquire();
    defer conn.release();
    try repository.writeSearchCache(conn, key, body);

    return tracks;
}

/// Читает кеш и освобождает соединение до запроса внешнего каталога.
fn readSearchCache(app: *App, arena: std.mem.Allocator, key: []const u8) !?[]const u8 {
    const conn = try app.db.acquire();
    defer conn.release();
    return repository.readSearchCache(conn, arena, key);
}

/// Разрешает ID через каталог и атомарно добавляет общий трек в личную библиотеку.
pub fn addToLibrary(app: *App, arena: std.mem.Allocator, user: []const u8, input: model.Selection) ![]const u8 {
    try model.validateExternalId(input.external_id);
    const key = try std.fmt.allocPrint(arena, "itunes:lookup:US:{s}", .{input.external_id});
    const track = if (try readSearchCache(app, arena, key)) |body|
        (try std.json.parseFromSlice(model.SearchTrack, arena, body, .{ .allocate = .alloc_always })).value
    else
        try app.catalog.lookup(arena, input.external_id);

    const conn = try app.db.acquire();
    defer conn.release();
    try repository.writeSearchCache(conn, key, try std.json.Stringify.valueAlloc(arena, track, .{}));
    try conn.begin();
    errdefer conn.rollback() catch {};
    const id = try create(conn, arena, app.storage.bucket, user, .{
        .title = track.title,
        .artist = track.artist,
    }, .{ .provider = "itunes", .external_id = track.external_id });
    try conn.commit();
    return id;
}

/// Переиспользует или создаёт общий трек у сервисной учётки, ставит загрузку в очередь и добавляет его в Uploads пользователя.
/// Принимает соединение с транзакцией вызывающего кода; ID трека выделяется в arena.
pub fn create(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    bucket: []const u8,
    user: []const u8,
    track: model.Track,
    source: ?model.Source,
) ![]const u8 {
    _ = try tracks_model.validateCreate(.{ .title = track.title, .artist = track.artist });
    const owner = try users_repository.ensureSystem(conn, arena);
    // Keep lock order consistent: user/playlist first, then shared track and jobs.
    const target = try playlists_repository.lockDefault(conn, arena, user);
    const id = try repository.getOrCreateTrack(conn, arena, bucket, track, source);
    _ = try jobs_repository.enqueue(
        conn,
        arena,
        model.download_job_kind,
        id,
        model.Payload{ .user_id = owner, .track_id = id, .track = track },
        0,
        3,
    );
    try playlists_repository.addTrack(conn, arena, target, user, id);

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
pub fn completeTask(db: *database.Database, task: model.Task) !void {
    const conn = try db.acquire();
    defer conn.release();

    try jobs_repository.complete(conn, task.job);
}

/// Фиксирует ошибку или планирует разрешённый повтор через 30 секунд; потерянную аренду игнорирует.
pub fn failTask(db: *database.Database, task: model.Task, retryable: bool) !void {
    const conn = try db.acquire();
    defer conn.release();

    jobs_repository.fail(conn, task.job, retryable, 30) catch |err| if (err != error.LeaseLost) return err;
}
