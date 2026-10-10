const httpz = @import("httpz");
const std = @import("std");
const builtin = @import("builtin");

/// Возвращает стандартную ошибку API; ошибки БД и хранилища дополнительно логирует.
/// Неизвестные ошибки передаёт вызывающему коду для обработки через uncaughtError.
pub fn failure(res: *httpz.Response, err: anyerror) !void {
    if (isInfrastructureFailure(err)) {
        std.log.err("Request infrastructure failure: {s}", .{@errorName(err)});
    }

    try respondFailure(res, err);
}

/// Определяет ошибки БД и хранилища, подробности которых скрываются в release-сборках.
fn isInfrastructureFailure(err: anyerror) bool {
    return switch (err) {
        error.DatabaseUnavailable, error.StorageUnavailable, error.StorageTimeout => true,
        else => false,
    };
}

/// Сопоставляет известную ошибку со статусом HTTP и кодом JSON-ответа.
/// Вне Debug заменяет ошибки инфраструктуры на 500/internal_error; неизвестные возвращает как есть.
fn respondFailure(res: *httpz.Response, err: anyerror) !void {
    if (builtin.mode != .Debug and isInfrastructureFailure(err)) {
        return respondError(res, 500, "internal_error");
    }

    const status: u16 = switch (err) {
        error.Unauthorized => 401,
        error.Forbidden => 403,
        error.NotFound,
        error.ReferenceNotFound,
        error.PlaylistNotFound,
        error.TrackNotFound,
        => 404,

        error.Conflict,
        error.AlreadyUploaded,
        error.UploadInProgress,
        error.TrackNotUploaded,
        error.HlsNotReady,
        error.TrackPreparationInProgress,
        error.DefaultPlaylistProtected,
        => 409,

        error.InvalidInput,
        error.InvalidPlaylistMetadata,
        error.InvalidTags,
        error.InvalidCredentials,
        error.InvalidPlaylistId,
        error.InvalidPlaylistIds,
        error.DuplicatePlaylistId,
        error.InvalidText,
        error.InvalidTrackId,
        error.InvalidJson,
        error.EmptyFile,
        error.EmptyImage,
        => 400,

        error.MetadataTooLarge, error.FileTooLarge, error.ImageTooLarge => 413,
        error.ExpectedApplicationJson, error.UnsupportedMediaType, error.UnsupportedContentEncoding => 415,
        error.DatabaseUnavailable => 503,
        error.StorageTimeout => 504,
        error.StorageUnavailable => 502,
        else => return err,
    };

    try respondError(res, status, switch (err) {
        error.Unauthorized => "unauthorized",
        error.Forbidden => "forbidden",

        error.NotFound => "not_found",
        error.ReferenceNotFound => "reference_not_found",
        error.PlaylistNotFound => "playlist_not_found",
        error.TrackNotFound => "track_not_found",

        error.Conflict => "conflict",
        error.AlreadyUploaded => "track_already_uploaded",
        error.UploadInProgress => "upload_in_progress",
        error.TrackNotUploaded => "track_not_uploaded",
        error.HlsNotReady => "hls_not_ready",
        error.TrackPreparationInProgress => "track_preparation_in_progress",
        error.DefaultPlaylistProtected => "default_playlist_protected",

        error.DatabaseUnavailable => "database_unavailable",
        error.StorageTimeout => "storage_timeout",
        error.StorageUnavailable => "storage_unavailable",

        error.InvalidPlaylistId => "invalid_playlist_id",
        error.InvalidPlaylistIds => "invalid_playlist_ids",
        error.DuplicatePlaylistId => "duplicate_playlist_id",
        error.InvalidText => "invalid_track_metadata",
        error.InvalidTrackId => "invalid_track_id",
        error.InvalidJson => "invalid_json",
        error.EmptyFile => "empty_file",
        error.EmptyImage => "empty_image",

        error.MetadataTooLarge => "metadata_too_large",
        error.FileTooLarge => "file_too_large",
        error.ImageTooLarge => "image_too_large",

        error.ExpectedApplicationJson => "expected_application_json",
        error.UnsupportedMediaType => "unsupported_media_type",
        error.UnsupportedContentEncoding => "unsupported_content_encoding",
        else => "invalid_input",
    });
}

/// Записывает статус и JSON вида {"error": code}, запрещая кеширование ответа.
fn respondError(res: *httpz.Response, status: u16, code: []const u8) !void {
    res.status = status;
    res.header("Cache-Control", "no-store");

    try res.json(.{ .@"error" = code }, .{});
}

/// Разбирает JSON запроса с лимитом по умолчанию; при некорректном запросе отправляет ошибку и возвращает null.
pub fn readJson(req: *httpz.Request, res: *httpz.Response, comptime T: type) !?T {
    return readJsonWithOptions(req, res, T, .{});
}

/// Ограничения для разбора JSON-тела запроса.
pub const JsonOptions = struct {
    /// Максимальный размер тела в байтах; по умолчанию 32 КиБ.
    max_bytes: usize = 32 * 1024,
};

/// Проверяет Content-Type, размер тела и соответствие JSON типу T.
/// При отказе отправляет стандартную ошибку и возвращает null; обработчик должен прекратить выполнение.
pub fn readJsonWithOptions(
    req: *httpz.Request,
    res: *httpz.Response,
    comptime T: type,
    options: JsonOptions,
) !?T {
    const header = req.header("content-type") orelse {
        try failure(res, error.ExpectedApplicationJson);
        return null;
    };

    const end = std.mem.indexOfScalar(u8, header, ';') orelse header.len;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, header[0..end], " \t"), "application/json")) {
        try failure(res, error.ExpectedApplicationJson);
        return null;
    }

    const body = req.body() orelse "";
    if (body.len > options.max_bytes) {
        try failure(res, error.MetadataTooLarge);
        return null;
    }

    return (req.json(T) catch {
        try failure(res, error.InvalidJson);
        return null;
    }) orelse {
        try failure(res, error.InvalidJson);
        return null;
    };
}

/// Передаёт готовый JSON без повторной сериализации и запрещает кеширование.
/// Не проверяет содержимое body; его память должна жить до отправки ответа.
pub fn sendJsonText(res: *httpz.Response, body: []const u8) void {
    res.header("Cache-Control", "no-store");
    res.content_type = .JSON;
    res.body = body;
}

test "infrastructure failures expose diagnostic codes only in Debug" {
    const Case = struct { err: anyerror, status: u16, code: []const u8 };

    for ([_]Case{
        .{ .err = error.DatabaseUnavailable, .status = 503, .code = "database_unavailable" },
        .{ .err = error.StorageUnavailable, .status = 502, .code = "storage_unavailable" },
        .{ .err = error.StorageTimeout, .status = 504, .code = "storage_timeout" },
    }) |case| {
        var context = httpz.testing.init(.{});
        defer context.deinit();

        try respondFailure(context.res, case.err);

        try context.expectStatus(if (builtin.mode == .Debug) case.status else 500);
        try context.expectJson(.{ .@"error" = if (builtin.mode == .Debug) case.code else "internal_error" });
        try context.expectHeader("Cache-Control", "no-store");
    }
}

test "client errors retain their contract in every build mode" {
    var context = httpz.testing.init(.{});
    defer context.deinit();

    try respondFailure(context.res, error.AlreadyUploaded);

    try context.expectStatus(409);
    try context.expectJson(.{ .@"error" = "track_already_uploaded" });

    try std.testing.expectError(error.UnexpectedFailure, respondFailure(context.res, error.UnexpectedFailure));
}
