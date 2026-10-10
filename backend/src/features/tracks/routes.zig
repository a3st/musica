const std = @import("std");
const httpz = @import("httpz");
const App = @import("../../app.zig").App;
const model = @import("model.zig");
const service = @import("service.zig");
const auth_service = @import("../auth/service.zig");
const auth_model = @import("../auth/model.zig");
const api = @import("../../helpers/api.zig");

/// Регистрирует маршруты создания, загрузки файла, чтения обложки и удаления трека.
pub fn register(router: *httpz.Router(*App, httpz.Action(*App))) void {
    router.post("/api/tracks", create, .{});
    router.put("/api/tracks/:id/file", upload, .{});
    router.delete("/api/tracks/:id", remove, .{});
    router.get("/api/tracks/:id/artwork", artwork, .{});
}

/// Выдаёт JPEG с проверкой доступа через сессию или share_token; приватные ответы не кешируются.
fn artwork(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = req.param("id") orelse return api.failure(res, error.InvalidTrackId);
    if (!model.isValidId(id)) return api.failure(res, error.InvalidTrackId);

    const query = req.query() catch return api.failure(res, error.InvalidInput);
    const token = query.get("share_token");
    if (token) |value| {
        if (!auth_model.isValidToken(value)) return api.failure(res, error.NotFound);
    }
    const user = auth_service.optionalUser(app, req, res.arena) catch |err| return api.failure(res, err);
    const hash = if (token) |value| auth_model.tokenHash(value) else null;

    res.body = service.readArtwork(app, res.arena, id, user, if (hash) |*value| value else null) catch |err|
        return api.failure(res, err);
    res.header("Content-Type", "image/jpeg");
    res.header("Cache-Control", "no-store");
    res.header("X-Content-Type-Options", "nosniff");
}

/// Удаляет трек через сервис и планирует очистку файлов; возвращает 204.
fn remove(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = req.param("id") orelse return api.failure(res, error.InvalidTrackId);
    if (!model.isValidId(id)) return api.failure(res, error.InvalidTrackId);

    const user = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);

    service.remove(app, res.arena, user, id) catch |err| return api.failure(res, err);

    res.status = 204;
    res.header("Cache-Control", "no-store");
}

/// Проверяет метаданные и создаёт трек без файла; возвращает ID и статус pending.
fn create(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const input = (try api.readJsonWithOptions(req, res, model.CreateTrack, .{ .max_bytes = 16 * 1024 })) orelse return;
    _ = model.validateCreate(input) catch |err| return api.failure(res, err);

    const user = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);

    const id = service.create(app, res.arena, user, input) catch |err| return api.failure(res, err);

    res.status = 201;
    res.header("Cache-Control", "no-store");

    try res.json(.{ .id = &id, .status = model.Status.pending }, .{});
}

/// Проверяет файл и загружает его для существующего трека; возвращает статус ready и адрес объекта.
fn upload(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = req.param("id") orelse return api.failure(res, error.InvalidTrackId);
    if (!model.isValidId(id)) return api.failure(res, error.InvalidTrackId);

    const mime = model.parseContentType(req.header("content-type") orelse "application/octet-stream") orelse
        return api.failure(res, error.UnsupportedMediaType);
    if (req.header("content-encoding")) |encoding| {
        if (!std.ascii.eqlIgnoreCase(encoding, "identity")) return api.failure(res, error.UnsupportedContentEncoding);
    }

    const data = req.body() orelse return api.failure(res, error.EmptyFile);
    if (data.len == 0) return api.failure(res, error.EmptyFile);
    if (data.len > app.max_upload_bytes) return api.failure(res, error.FileTooLarge);

    const user = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);

    const location = service.upload(app, res.arena, user, id, mime, data) catch |err| return api.failure(res, err);

    res.header("Cache-Control", "no-store");

    try res.json(.{
        .id = try std.ascii.allocLowerString(res.arena, id),
        .status = model.Status.ready,
        .bucket = location.bucket,
        .object_key = location.key,
        .size_bytes = data.len,
        .content_type = mime,
    }, .{});
}

test "POST rejects malformed JSON, missing fields and invalid metadata before DB access" {
    var app: App = undefined;
    app.max_upload_bytes = 3;
    const bodies = [_][]const u8{
        "not json",
        "{\"playlist_ids\":null,\"title\":\"Track\",\"artist\":\"Artist\"}",
        "{\"playlist_ids\":[\"abcdef01-1234-5678-abcd-123456789012\",\"ABCDEF01-1234-5678-ABCD-123456789012\"],\"title\":\"Track\",\"artist\":\"Artist\"}",
        "{\"playlist_ids\":[\"11111111-1111-4111-8111-111111111111\"],\"title\":\"Track\"}",
        "{\"playlist_ids\":[\"bad\"],\"title\":\"Track\",\"artist\":\"Artist\"}",
        "{\"playlist_ids\":[\"11111111-1111-4111-8111-111111111111\"],\"title\":\" \",\"artist\":\"Artist\"}",
    };

    for (bodies) |body| {
        var context = httpz.testing.init(.{});
        defer context.deinit();
        context.header("content-type", "application/json");
        context.body(body);
        try create(&app, context.req, context.res);

        try context.expectStatus(400);
    }
}

test "PUT rejects invalid ID, empty file, unsupported MIME and oversize body" {
    var app: App = undefined;
    app.max_upload_bytes = 3;
    const Case = struct {
        id: ?[]const u8 = "11111111-1111-4111-8111-111111111111",
        mime: []const u8 = "audio/mpeg",
        encoding: ?[]const u8 = null,
        body: []const u8 = "a",
        status: u16,
        code: []const u8,
    };

    const cases = [_]Case{
        .{ .id = null, .status = 400, .code = "invalid_track_id" },
        .{ .id = "bad", .status = 400, .code = "invalid_track_id" },
        .{ .body = "", .status = 400, .code = "empty_file" },
        .{ .mime = "multipart/form-data", .status = 415, .code = "unsupported_media_type" },
        .{ .encoding = "gzip", .status = 415, .code = "unsupported_content_encoding" },
        .{ .body = "abcd", .status = 413, .code = "file_too_large" },
    };

    for (cases) |case| {
        var context = httpz.testing.init(.{});
        defer context.deinit();
        if (case.id) |value| context.param("id", value);
        context.header("content-type", case.mime);
        if (case.encoding) |value| context.header("content-encoding", value);
        context.body(case.body);
        try upload(&app, context.req, context.res);

        try context.expectStatus(case.status);
        try context.expectJson(.{ .@"error" = case.code });
        try context.expectHeader("Cache-Control", "no-store");
    }
}

test "valid track creation and upload require a session" {
    var app: App = undefined;
    app.max_upload_bytes = 1024;
    var creation = httpz.testing.init(.{});
    defer creation.deinit();
    creation.header("content-type", "application/json");
    creation.body("{\"title\":\"Track\",\"artist\":\"Artist\"}");
    try create(&app, creation.req, creation.res);

    try creation.expectStatus(401);

    var file = httpz.testing.init(.{});
    defer file.deinit();
    file.param("id", "11111111-1111-4111-8111-111111111111");
    file.header("content-type", "audio/mpeg");
    file.body("audio");
    try upload(&app, file.req, file.res);

    try file.expectStatus(401);
}

test "shared API helpers preserve track error codes and the 16 KiB JSON limit" {
    var app: App = undefined;
    app.max_upload_bytes = 1024;
    const Case = struct { body: []const u8, status: u16 = 400, code: []const u8 };

    const cases = [_]Case{
        .{ .body = "not json", .code = "invalid_json" },
        .{ .body = "{\"playlist_ids\":[\"bad\"],\"title\":\"Track\",\"artist\":\"Artist\"}", .code = "invalid_playlist_id" },
        .{ .body = "{\"playlist_ids\":[\"abcdef01-1234-5678-abcd-123456789012\",\"ABCDEF01-1234-5678-ABCD-123456789012\"],\"title\":\"Track\",\"artist\":\"Artist\"}", .code = "duplicate_playlist_id" },
        .{ .body = "{\"title\":\" \",\"artist\":\"Artist\"}", .code = "invalid_track_metadata" },
        .{ .body = "{\"title\":\"" ++ "a" ** (16 * 1024) ++ "\",\"artist\":\"Artist\"}", .status = 413, .code = "metadata_too_large" },
    };

    for (cases) |case| {
        var context = httpz.testing.init(.{});
        defer context.deinit();
        context.header("content-type", "application/json; charset=utf-8");
        context.body(case.body);
        try create(&app, context.req, context.res);

        try context.expectStatus(case.status);
        try context.expectJson(.{ .@"error" = case.code });
        try context.expectHeader("Cache-Control", "no-store");
    }
}
