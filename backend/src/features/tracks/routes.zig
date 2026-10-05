const std = @import("std");
const httpz = @import("httpz");
const app_module = @import("../../app.zig");
const App = app_module.App;
const respondError = app_module.respondError;
const model = @import("model.zig");
const service = @import("service.zig");

pub fn register(router: *httpz.Router(*App, httpz.Action(*App))) void {
    router.post("/api/tracks", create, .{});
    router.put("/api/tracks/:id/file", upload, .{});
}

fn create(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const header = req.header("content-type") orelse return respondError(res, 415, "expected_application_json");
    const end = std.mem.indexOfScalar(u8, header, ';') orelse header.len;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, header[0..end], " \t"), "application/json"))
        return respondError(res, 415, "expected_application_json");
    const body = req.body() orelse return respondError(res, 400, "invalid_json");
    if (body.len > 16 * 1024) return respondError(res, 413, "metadata_too_large");
    const input = (req.json(model.CreateTrack) catch return respondError(res, 400, "invalid_json")) orelse
        return respondError(res, 400, "invalid_json");
    const id = service.create(app, input) catch |err| return handleError(res, err);
    res.status = 201;
    res.header("Cache-Control", "no-store");
    try res.json(.{ .id = &id, .status = "pending" }, .{});
}

fn upload(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = req.param("id") orelse return respondError(res, 400, "invalid_track_id");
    if (!model.validId(id)) return respondError(res, 400, "invalid_track_id");
    const mime = model.contentType(req.header("content-type") orelse "application/octet-stream") orelse
        return respondError(res, 415, "unsupported_media_type");
    if (req.header("content-encoding")) |encoding| {
        if (!std.ascii.eqlIgnoreCase(encoding, "identity")) return respondError(res, 415, "unsupported_content_encoding");
    }
    const data = req.body() orelse return respondError(res, 400, "empty_file");
    if (data.len == 0) return respondError(res, 400, "empty_file");
    if (data.len > app.max_upload_bytes) return respondError(res, 413, "file_too_large");
    const key = service.upload(app, res.arena, id, mime, data) catch |err| return handleError(res, err);
    res.header("Cache-Control", "no-store");
    try res.json(.{
        .id = try std.ascii.allocLowerString(res.arena, id),
        .status = "ready",
        .bucket = app.storage.bucket,
        .object_key = key,
        .size_bytes = data.len,
        .content_type = mime,
    }, .{});
}

fn handleError(res: *httpz.Response, err: anyerror) !void {
    switch (err) {
        error.InvalidAlbumId => try respondError(res, 400, "invalid_album_id"),
        error.InvalidText => try respondError(res, 400, "invalid_track_metadata"),
        error.AlbumNotFound => try respondError(res, 404, "album_not_found"),
        error.TrackNotFound => try respondError(res, 404, "track_not_found"),
        error.AlreadyUploaded => try respondError(res, 409, "track_already_uploaded"),
        error.UploadInProgress => try respondError(res, 409, "upload_in_progress"),
        error.DatabaseUnavailable => try respondError(res, 503, "database_unavailable"),
        error.StorageTimeout => try respondError(res, 504, "storage_timeout"),
        error.StorageUnavailable => try respondError(res, 502, "storage_unavailable"),
        else => return err,
    }
}

test "POST rejects malformed JSON, missing fields and invalid metadata before DB access" {
    var app: App = .{ .db = undefined, .storage = undefined, .max_upload_bytes = 3 };
    const bodies = [_][]const u8{
        "not json",
        "{\"album_id\":\"11111111-1111-4111-8111-111111111111\",\"title\":\"Track\"}",
        "{\"album_id\":\"bad\",\"title\":\"Track\",\"artist\":\"Artist\"}",
        "{\"album_id\":\"11111111-1111-4111-8111-111111111111\",\"title\":\" \",\"artist\":\"Artist\"}",
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
    var app: App = .{ .db = undefined, .storage = undefined, .max_upload_bytes = 3 };
    const Case = struct { id: []const u8 = "11111111-1111-4111-8111-111111111111", mime: []const u8 = "audio/mpeg", body: []const u8 = "a", status: u16 };
    const cases = [_]Case{
        .{ .id = "bad", .status = 400 },
        .{ .body = "", .status = 400 },
        .{ .mime = "multipart/form-data", .status = 415 },
        .{ .body = "abcd", .status = 413 },
    };
    for (cases) |case| {
        var context = httpz.testing.init(.{});
        defer context.deinit();
        context.param("id", case.id);
        context.header("content-type", case.mime);
        context.body(case.body);
        try upload(&app, context.req, context.res);
        try context.expectStatus(case.status);
    }
}
