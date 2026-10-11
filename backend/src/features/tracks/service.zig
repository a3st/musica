const std = @import("std");
const App = @import("../../app.zig").App;
const model = @import("model.zig");
const repository = @import("repository.zig");
const operations = @import("operations.zig");
const playlists_repository = @import("../playlists/repository.zig");
const imports_model = @import("../imports/model.zig");
const cleanup_service = @import("cleanup_service.zig");
const jobs_repository = @import("../../infrastructure/jobs/repository.zig");
const Job = @import("../../infrastructure/jobs/model.zig").Job;
const auth_model = @import("../auth/model.zig");

/// Ищет пользовательские треки в публичных, собственных и доступных по членству плейлистах.
pub fn searchLibrary(app: *App, arena: std.mem.Allocator, user: []const u8, query: []const u8) ![]const model.LibraryMatch {
    const validated = try model.validateSearch(query);
    var words: std.ArrayList([]const u8) = .empty;
    var tokens = std.mem.tokenizeAny(u8, validated, " \t\r\n");
    while (tokens.next()) |word| try words.append(arena, word);

    const conn = try app.db.acquire();
    defer conn.release();

    return repository.searchLibrary(conn, arena, user, try std.json.Stringify.valueAlloc(arena, words.items, .{}));
}

/// Проверяет метаданные и атомарно создаёт трек с привязками к Uploads и дополнительным плейлистам.
pub fn create(app: *App, arena: std.mem.Allocator, user: []const u8, raw: model.CreateTrack) ![36]u8 {
    const input = try model.validateCreate(raw);

    const conn = try app.db.acquire();
    defer conn.release();

    try conn.begin();
    errdefer conn.rollback() catch {};

    const uploads_playlist_id = try playlists_repository.lockDefault(conn, arena, user);
    const id = try repository.create(conn, arena, user, app.storage.bucket, input);

    try playlists_repository.addTrack(conn, arena, uploads_playlist_id, user, &id);
    for (input.playlist_ids) |playlist_id| {
        try playlists_repository.lockForWrite(conn, arena, playlist_id, user, false);
        try playlists_repository.addTrack(conn, arena, playlist_id, user, &id);
    }

    try conn.commit();

    return id;
}

/// Проверяет наличие трека в Uploads и удаляет его из библиотеки по правилам владения в одной транзакции.
pub fn remove(app: *App, arena: std.mem.Allocator, user: []const u8, id: []const u8) !void {
    const conn = try app.db.acquire();
    defer conn.release();

    try conn.begin();
    errdefer conn.rollback() catch {};

    const playlist = try playlists_repository.lockDefault(conn, arena, user);
    try playlists_repository.requireTrack(conn, arena, playlist, id);
    try operations.removeFromLibrary(conn, arena, user, id, playlist);

    try conn.commit();
}

/// Загружает исходный файл пользовательского трека и публикует его адрес после успешной записи в S3.
pub fn upload(
    app: *App,
    arena: std.mem.Allocator,
    user: []const u8,
    id: []const u8,
    mime: []const u8,
    data: []const u8,
) !model.UploadLocation {
    return uploadImpl(app, arena, user, id, mime, data, null);
}

/// Загружает исходный файл от имени фоновой задачи; проверяет её аренду до записи и публикации.
pub fn uploadForJob(
    app: *App,
    arena: std.mem.Allocator,
    user: []const u8,
    id: []const u8,
    mime: []const u8,
    data: []const u8,
    job: Job,
) !model.UploadLocation {
    return uploadImpl(app, arena, user, id, mime, data, job);
}

/// Резервирует аренду загрузки и задачу очистки, записывает файл в S3, затем публикует его в отдельной транзакции.
/// Во время обращения к S3 соединение БД освобождено; неудачная загрузка оставляет задачу очистки.
fn uploadImpl(
    app: *App,
    arena: std.mem.Allocator,
    user: []const u8,
    id: []const u8,
    mime: []const u8,
    data: []const u8,
    guard: ?Job,
) !model.UploadLocation {
    const token = try auth_model.generateToken(app.storage.io);
    const attempt = try std.fmt.allocPrint(
        arena,
        "{s}-{s}-{s}-{s}-{s}",
        .{ token[0..8], token[8..12], token[12..16], token[16..20], token[20..32] },
    );
    var reservation: []const u8 = undefined;
    var lease: Job = undefined;

    const canonical_id = try std.ascii.allocLowerString(arena, id);

    const location = blk: {
        const conn = try app.db.acquire();
        defer conn.release();

        try conn.begin();
        errdefer conn.rollback() catch {};

        const original = try repository.lockForUpload(conn, arena, canonical_id, user);
        if (guard) |job| {
            try jobs_repository.heartbeat(conn, job, 120);
        } else if (try jobs_repository.findByKey(conn, arena, imports_model.download_job_kind, canonical_id)) |job| {
            if (try jobs_repository.isActive(conn, arena, job.id)) return error.UploadInProgress;
        }
        const value: model.UploadLocation = .{
            .bucket = original.bucket,
            .key = try std.fmt.allocPrint(arena, "{s}/{s}", .{ original.key, attempt }),
        };
        lease = jobs_repository.acquireLease(
            conn,
            arena,
            model.upload_job_kind,
            canonical_id,
            attempt,
            model.UploadPayload{ .track_id = canonical_id, .bucket = value.bucket, .key = value.key },
            120,
        ) catch |err| {
            if (err == error.LeaseLost) return error.UploadInProgress;

            return err;
        };
        reservation = try cleanup_service.scheduleFallbackCleanup(conn, arena, value.bucket, value.key);

        try conn.commit();

        break :blk value;
    };

    // Release ownership on failure; cleanup remains durable and each retry has a distinct key.
    errdefer {
        const protection = app.storage.io.swapCancelProtection(.blocked);
        defer _ = app.storage.io.swapCancelProtection(protection);
        releaseUpload(app, lease) catch |err| std.log.err("Upload release failed: {s}", .{@errorName(err)});
    }

    app.storage.putInBucket(arena, location.bucket, location.key, mime, data) catch |err| {
        std.log.err("Track storage upload failed: {s} (track={s}, upload_attempt={s})", .{
            @errorName(err),
            canonical_id,
            lease.attempt_id orelse "unknown",
        });
        if (err == error.Canceled) return err;
        if (err == error.StorageTimeout) return error.StorageTimeout;

        return error.StorageUnavailable;
    };

    {
        const conn = try app.db.acquire();
        defer conn.release();

        try conn.begin();
        errdefer conn.rollback() catch {};

        try repository.lock(conn, arena, canonical_id);
        if (guard) |job| try jobs_repository.heartbeat(conn, job, 120);
        jobs_repository.complete(conn, lease) catch |err| {
            if (err == error.LeaseLost) return error.UploadInProgress;

            return err;
        };
        try repository.finishUpload(conn, canonical_id, location.key, mime, data.len);
        _ = try jobs_repository.enqueue(
            conn,
            arena,
            model.metadata_job_kind,
            canonical_id,
            model.MetadataPayload{
                .track_id = canonical_id,
                .bucket = location.bucket,
                .key = location.key,
                .size = data.len,
            },
            0,
            3,
        );
        try cleanup_service.cancelScheduledCleanup(conn, reservation);

        try conn.commit();
    }

    return location;
}

/// Помечает текущую загрузку неуспешной; потерянная аренда не считается дополнительной ошибкой.
fn releaseUpload(app: *App, lease: Job) !void {
    const conn = try app.db.acquire();
    defer conn.release();

    jobs_repository.fail(conn, lease, false, 0) catch |err| if (err != error.LeaseLost) return err;
}

/// Проверяет доступ к обложке и читает JPEG из S3 после освобождения соединения БД.
pub fn readArtwork(
    app: *App,
    arena: std.mem.Allocator,
    id: []const u8,
    user: ?[]const u8,
    share_hash: ?[]const u8,
) ![]const u8 {
    const location = blk: {
        const conn = try app.db.acquire();
        defer conn.release();

        break :blk try repository.readArtwork(conn, arena, id, user, share_hash);
    };

    return app.storage.getInBucket(arena, location.bucket, location.key, model.max_artwork_bytes) catch |err| {
        std.log.err("Track artwork storage read failed: {s}", .{@errorName(err)});
        if (err == error.Canceled or err == error.StorageTimeout) return err;
        return error.StorageUnavailable;
    };
}
