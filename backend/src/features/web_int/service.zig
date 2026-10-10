const std = @import("std");
const App = @import("../../app.zig").App;
const database = @import("../../infrastructure/database.zig");
const catalog_model = @import("../../infrastructure/catalog/model.zig");
const model = @import("model.zig");
const repository = @import("repository.zig");
const jobs_repository = @import("../../infrastructure/jobs/repository.zig");
const tracks_model = @import("../tracks/model.zig");
const playlists_repository = @import("../playlists/repository.zig");
const users_repository = @import("../users/repository.zig");

/// Ищет до 25 загруженных сервисных треков по всем словам названия и исполнителя.
fn searchLocal(app: *App, arena: std.mem.Allocator, query: []const u8) ![]const model.Track {
    const validated = try model.validateSearch(query);
    var words: std.ArrayList([]const u8) = .empty;
    var tokens = std.mem.tokenizeAny(u8, validated, " \t\r\n");
    while (tokens.next()) |word| try words.append(arena, word);

    const conn = try app.db.acquire();
    defer conn.release();
    return repository.searchLocal(conn, arena, try std.json.Stringify.valueAlloc(arena, words.items, .{}));
}

/// Ищет загруженные сервисные треки и каталог; совпадения каталога заменяются локальными результатами.
pub fn search(app: *App, arena: std.mem.Allocator, query: []const u8) !model.SearchResult {
    const validated_query = try model.validateSearch(query);
    const local = try searchLocal(app, arena, validated_query);
    const sources = try app.catalog.searchSources(arena, validated_query);
    const catalog = searchSources(app, arena, sources, validated_query, searchProvider, .fromSeconds(30)) catch |err| {
        if (err == error.Canceled or err == error.OutOfMemory or local.len == 0) return err;

        std.log.warn("Catalog unavailable; returning local search results: {s}", .{@errorName(err)});
        return .{ .library = local, .catalog = &.{} };
    };

    const conn = try app.db.acquire();
    defer conn.release();

    return .{
        .library = local,
        .catalog = try repository.deduplicateSearchResults(conn, arena, local, catalog),
    };
}

const SearchOperation = *const fn (*App, std.mem.Allocator, catalog_model.SearchSource, []const u8) anyerror![]const model.SearchTrack;

/// Данные одной параллельной операции; арена освобождается только после остановки её задач.
const SearchTask = struct {
    arena: std.heap.ArenaAllocator,
    source: catalog_model.SearchSource,
    result: anyerror![]const model.SearchTrack = error.CatalogUnavailable,
};

/// Запускает источники группами до четырёх; копирует ответы в arena до освобождения рабочих арен.
fn searchSources(
    app: *App,
    arena: std.mem.Allocator,
    sources: []const catalog_model.SearchSource,
    query: []const u8,
    operation: SearchOperation,
    timeout: std.Io.Duration,
) ![]const model.SearchTrack {
    const io = app.io;
    var tracks: std.ArrayList(model.SearchTrack) = .empty;
    var successful_sources: usize = 0;
    var first_failure: ?anyerror = null;
    var offset: usize = 0;

    while (offset < sources.len) {
        const count = @min(4, sources.len - offset);
        var tasks: [4]SearchTask = undefined;
        for (tasks[0..count], sources[offset..][0..count]) |*task, source| {
            task.* = .{
                .arena = std.heap.ArenaAllocator.init(app.allocator),
                .source = source,
            };
        }
        defer for (tasks[0..count]) |*task| task.arena.deinit();

        var group: std.Io.Group = .init;
        defer group.cancel(io);

        for (tasks[0..count]) |*task| {
            try group.concurrent(io, runSearchTask, .{ app, task, query, operation, timeout });
        }
        try group.await(io);

        for (tasks[0..count]) |*task| {
            const results = task.result catch |err| {
                if (err == error.Canceled or err == error.OutOfMemory) return err;

                std.log.warn("Catalog source {s} search failed: {s}", .{ @tagName(task.source.provider), @errorName(err) });
                if (first_failure == null) first_failure = err;
                continue;
            };
            successful_sources += 1;

            for (results) |track| {
                try tracks.append(arena, try copySearchTrack(arena, track));
            }
        }
        offset += count;
    }

    if (successful_sources == 0) return first_failure orelse error.CatalogUnavailable;

    return tracks.toOwnedSlice(arena);
}

/// Ограничивает всё чтение источника таймаутом, включая БД; отмена дожидается завершения вложенных задач.
fn runSearchTask(
    app: *App,
    task: *SearchTask,
    query: []const u8,
    operation: SearchOperation,
    timeout: std.Io.Duration,
) void {
    task.result = searchWithTimeout(app, task, query, operation, timeout);
}

/// Соревнуется с таймером; рабочая арена остаётся доступной до cancelDiscard.
fn searchWithTimeout(
    app: *App,
    task: *SearchTask,
    query: []const u8,
    operation: SearchOperation,
    timeout: std.Io.Duration,
) ![]const model.SearchTrack {
    const Result = union(enum) {
        response: anyerror![]const model.SearchTrack,
        deadline: anyerror!void,
    };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(app.io, &buffer);
    defer select.cancelDiscard();

    try select.concurrent(.response, invokeSearchOperation, .{ operation, app, task.arena.allocator(), task.source, query });
    try select.concurrent(.deadline, searchDeadline, .{ app.io, timeout });

    return switch (try select.await()) {
        .response => |result| result,
        .deadline => |result| {
            try result;
            return error.CatalogUnavailable;
        },
    };
}

/// Передаёт выбранную операцию в std.Io через функцию с известной сигнатурой.
fn invokeSearchOperation(
    operation: SearchOperation,
    app: *App,
    arena: std.mem.Allocator,
    source: catalog_model.SearchSource,
    query: []const u8,
) ![]const model.SearchTrack {
    return operation(app, arena, source, query);
}

/// Ограничивает время одной поисковой операции.
fn searchDeadline(io: std.Io, timeout: std.Io.Duration) !void {
    try std.Io.sleep(io, timeout, .awake);
}

/// Переносит все строки из рабочей арены в арену HTTP-ответа.
fn copySearchTrack(arena: std.mem.Allocator, track: model.SearchTrack) !model.SearchTrack {
    return .{
        .provider = track.provider,
        .external_id = try arena.dupe(u8, track.external_id),
        .title = try arena.dupe(u8, track.title),
        .artist = try arena.dupe(u8, track.artist),
        .album = if (track.album) |value| try arena.dupe(u8, value) else null,
        .artwork_url = if (track.artwork_url) |value| try arena.dupe(u8, value) else null,
        .source_url = if (track.source_url) |value| try arena.dupe(u8, value) else null,
    };
}

/// Читает кеш одного источника; при промахе запрашивает провайдера и сохраняет успешный ответ, включая пустой.
fn searchProvider(
    app: *App,
    arena: std.mem.Allocator,
    source: catalog_model.SearchSource,
    query: []const u8,
) ![]const model.SearchTrack {
    if (try readSearchCache(app, arena, source.cache_key)) |body| {
        return (try std.json.parseFromSlice([]const model.SearchTrack, arena, body, .{ .allocate = .alloc_always })).value;
    }

    const tracks = try app.catalog.search(arena, source.provider, query);
    const body = try std.json.Stringify.valueAlloc(arena, tracks, .{});
    const conn = try app.db.acquire();
    defer conn.release();
    try repository.writeSearchCache(conn, source.cache_key, body);

    return tracks;
}

/// Читает кеш и освобождает соединение до запроса внешнего каталога.
fn readSearchCache(app: *App, arena: std.mem.Allocator, key: []const u8) !?[]const u8 {
    const conn = try app.db.acquire();
    defer conn.release();
    return repository.readSearchCache(conn, arena, key);
}

/// Разрешает ID через каталог, ставит загрузку в очередь и при необходимости добавляет в библиотеку.
pub fn selectTrack(app: *App, arena: std.mem.Allocator, user: []const u8, input: model.Selection) ![]const u8 {
    try model.validateExternalId(input.external_id);
    const key = try app.catalog.lookupCacheKey(arena, input.provider, input.external_id);
    const track = if (try readSearchCache(app, arena, key)) |body|
        (try std.json.parseFromSlice(model.SearchTrack, arena, body, .{ .allocate = .alloc_always })).value
    else
        try app.catalog.lookup(arena, input.provider, input.external_id);

    const conn = try app.db.acquire();
    defer conn.release();
    try repository.writeSearchCache(conn, key, try std.json.Stringify.valueAlloc(arena, track, .{}));
    try conn.begin();
    errdefer conn.rollback() catch {};

    // Lock the playlist before the shared track and its jobs.
    const uploads = if (input.add_to_library) try playlists_repository.lockDefault(conn, arena, user) else null;
    const id = try ensureDownload(
        conn,
        arena,
        app.storage.bucket,
        .{ .title = track.title, .artist = track.artist },
        .{ .provider = @tagName(track.provider), .external_id = track.external_id },
    );

    if (uploads) |playlist| try playlists_repository.addTrack(conn, arena, playlist, user, id);

    try conn.commit();
    return id;
}

/// Переиспользует или создаёт общий трек у сервисной учётки и ставит загрузку в очередь.
/// Принимает соединение с транзакцией вызывающего кода; ID трека выделяется в arena.
pub fn ensureDownload(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    bucket: []const u8,
    track: model.CatalogTrack,
    source: ?model.Source,
) ![]const u8 {
    const input = try model.validateTrack(track);
    const owner = try users_repository.ensureSystem(conn, arena);
    const id = try repository.getOrCreateCatalogTrack(conn, arena, owner, bucket, input, source);

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

/// Читает общий трек и состояние загрузки, не добавляя его в библиотеку.
pub fn readPlayback(app: *App, arena: std.mem.Allocator, id: []const u8) !model.Playback {
    if (!tracks_model.isValidId(id)) return error.InvalidTrackId;
    const conn = try app.db.acquire();
    defer conn.release();
    const track = try repository.readPlaybackTrack(conn, arena, id);
    const job = try jobs_repository.findByKey(conn, arena, model.download_job_kind, id);
    return .{ .track = track, .download = if (job) |value| value.state else null };
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

test "Parallel catalog search limits concurrency and keeps results after worker arenas are freed" {
    const Fixture = struct {
        var started: std.atomic.Value(usize) = .init(0);
        var active: std.atomic.Value(usize) = .init(0);
        var maximum: std.atomic.Value(usize) = .init(0);
        var barrier: std.Io.Event = .unset;

        fn search(app: *App, arena: std.mem.Allocator, source: catalog_model.SearchSource, query: []const u8) ![]const model.SearchTrack {
            const count = active.fetchAdd(1, .seq_cst) + 1;
            defer _ = active.fetchSub(1, .seq_cst);
            _ = maximum.fetchMax(count, .seq_cst);
            if (started.fetchAdd(1, .seq_cst) + 1 == 4) barrier.set(app.io);
            try barrier.wait(app.io);
            try std.Io.sleep(app.io, .fromMilliseconds(10), .awake);

            const tracks = try arena.alloc(model.SearchTrack, 1);
            tracks[0] = .{
                .provider = source.provider,
                .external_id = try arena.dupe(u8, source.cache_key),
                .title = try arena.dupe(u8, query),
                .artist = try arena.dupe(u8, "Artist"),
                .album = try arena.dupe(u8, "Album"),
                .artwork_url = try arena.dupe(u8, "https://example.com/artwork.jpg"),
                .source_url = try arena.dupe(u8, "https://example.com/song"),
            };
            return tracks;
        }
    };
    var app: App = undefined;
    app.io = std.testing.io;
    app.allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sources: [6]catalog_model.SearchSource = undefined;
    for (&sources, 0..) |*source, index| {
        source.* = .{
            .provider = .itunes,
            .cache_key = try std.fmt.allocPrint(arena.allocator(), "{d}", .{index}),
        };
    }

    const tracks = try searchSources(&app, arena.allocator(), &sources, "Song (Live Remix)", Fixture.search, .fromSeconds(2));

    try std.testing.expectEqual(@as(usize, 4), Fixture.maximum.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 6), Fixture.started.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), Fixture.active.load(.seq_cst));
    try std.testing.expectEqual(sources.len, tracks.len);
    for (tracks, sources) |track, source| {
        try std.testing.expectEqualStrings(source.cache_key, track.external_id);
        try std.testing.expectEqualStrings("Song (Live Remix)", track.title);
        try std.testing.expectEqualStrings("Artist", track.artist);
        try std.testing.expectEqualStrings("Album", track.album.?);
        try std.testing.expectEqualStrings("https://example.com/artwork.jpg", track.artwork_url.?);
        try std.testing.expectEqualStrings("https://example.com/song", track.source_url.?);
    }
}

test "Parallel catalog search tolerates failed sources and treats empty answers as success" {
    const Fixture = struct {
        fn search(_: *App, _: std.mem.Allocator, source: catalog_model.SearchSource, _: []const u8) ![]const model.SearchTrack {
            if (std.mem.eql(u8, source.cache_key, "failed")) return error.CatalogUnavailable;
            if (std.mem.eql(u8, source.cache_key, "empty")) return &.{};

            return &.{.{ .provider = .itunes, .external_id = "1", .title = "Song", .artist = "Artist" }};
        }
    };
    var app: App = undefined;
    app.io = std.testing.io;
    app.allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]catalog_model.SearchSource{
        .{ .provider = .itunes, .cache_key = "failed" },
        .{ .provider = .itunes, .cache_key = "empty" },
        .{ .provider = .itunes, .cache_key = "successful" },
    };

    const tracks = try searchSources(&app, arena.allocator(), &sources, "query", Fixture.search, .fromSeconds(2));
    try std.testing.expectEqual(@as(usize, 1), tracks.len);
    try std.testing.expectEqualStrings("Song", tracks[0].title);
    try std.testing.expectEqual(@as(usize, 0), (try searchSources(&app, arena.allocator(), sources[0..2], "query", Fixture.search, .fromSeconds(2))).len);
    try std.testing.expectError(error.CatalogUnavailable, searchSources(&app, arena.allocator(), sources[0..1], "query", Fixture.search, .fromSeconds(2)));
}

test "Parallel catalog search drains workers on timeout and parent cancellation" {
    const Fixture = struct {
        var started: std.Io.Event = .unset;
        var active: std.atomic.Value(usize) = .init(0);

        fn search(app: *App, arena: std.mem.Allocator, _: catalog_model.SearchSource, _: []const u8) ![]const model.SearchTrack {
            _ = active.fetchAdd(1, .seq_cst);
            defer _ = active.fetchSub(1, .seq_cst);
            _ = try arena.alloc(u8, 1024);
            started.set(app.io);
            try std.Io.sleep(app.io, .fromSeconds(60), .awake);
            return &.{};
        }
    };
    var app: App = undefined;
    app.io = std.testing.io;
    app.allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]catalog_model.SearchSource{.{ .provider = .itunes, .cache_key = "stalled" }};

    try std.testing.expectError(error.CatalogUnavailable, searchSources(&app, arena.allocator(), &sources, "query", Fixture.search, .fromMilliseconds(50)));
    try std.testing.expectEqual(@as(usize, 0), Fixture.active.load(.seq_cst));

    Fixture.started = .unset;
    var future = try std.testing.io.concurrent(searchSources, .{ &app, arena.allocator(), &sources, "query", Fixture.search, std.Io.Duration.fromSeconds(2) });
    defer _ = future.cancel(std.testing.io) catch {};
    try Fixture.started.wait(std.testing.io);
    try std.testing.expectError(error.Canceled, future.cancel(std.testing.io));
    try std.testing.expectEqual(@as(usize, 0), Fixture.active.load(.seq_cst));
}
