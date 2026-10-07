const std = @import("std");
const httpz = @import("httpz");
const App = @import("../../app.zig").App;
const api = @import("../../helpers/api.zig");
const auth = @import("../auth/service.zig");
const tokens = @import("../auth/model.zig");
const validId = @import("../tracks/model.zig").validId;
const model = @import("model.zig");
const repository = @import("repository.zig");
const service = @import("service.zig");

pub fn register(router: *httpz.Router(*App, httpz.Action(*App))) void {
    router.post("/api/playlists", create, .{});
    router.get("/api/playlists", list, .{});
    router.get("/api/playlists/:id", read, .{});
    router.put("/api/playlists/:id", update, .{});
    router.put("/api/playlists/:id/image", image, .{});
    router.get("/api/playlists/:id/image", readImage, .{});
    router.put("/api/playlists/:id/members/:user_id", member, .{});
    router.delete("/api/playlists/:id/members/:user_id", removeMember, .{});
    router.put("/api/playlists/:id/tracks/:track_id", addTrack, .{});
    router.delete("/api/playlists/:id/tracks/:track_id", removeTrack, .{});
    router.post("/api/playlists/:id/share-link", shareLink, .{});
    router.delete("/api/playlists/:id/share-link", revokeLink, .{});
    router.get("/api/shared/playlists/:token", shared, .{});
}

fn list(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    api.jsonText(res, repository.list(app.db, res.arena, user) catch |err| return api.failure(res, err));
}

fn readImage(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const playlist = id(req, "id") catch |err| return api.failure(res, err);
    const user = auth.optionalUser(app, req, res.arena) catch |err| return api.failure(res, err);
    const body = repository.read(app.db, res.arena, playlist, user) catch |err| return api.failure(res, err);
    const data = try std.json.parseFromSliceLeaky(struct { image_key: ?[]const u8 }, res.arena, body, .{ .ignore_unknown_fields = true });
    const key = data.image_key orelse return api.failure(res, error.NotFound);
    const bytes = app.storage.get(res.arena, key, 5 * 1024 * 1024) catch |err| {
        std.log.err("Playlist image download failed: {s}", .{@errorName(err)});
        return api.failure(res, if (err == error.StorageTimeout) error.StorageTimeout else error.StorageUnavailable);
    };
    const mime = if (service.validImage("image/png", bytes)) "image/png" else if (service.validImage("image/jpeg", bytes)) "image/jpeg" else if (service.validImage("image/webp", bytes)) "image/webp" else return api.failure(res, error.StorageUnavailable);
    res.body = bytes;
    res.header("Content-Type", mime);
    res.header("Cache-Control", "no-store");
}

fn id(req: *httpz.Request, name: []const u8) ![]const u8 {
    const value = req.param(name) orelse return error.InvalidInput;
    if (!validId(value)) return error.InvalidInput;
    return value;
}

fn create(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const input = (try api.json(req, res, model.CreatePlaylist)) orelse return;
    const user = auth.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    const playlist = service.create(app, res.arena, user, input) catch |err| return api.failure(res, err);
    res.status = 201;
    res.header("Cache-Control", "no-store");
    try res.json(.{ .id = playlist, .visibility = input.visibility }, .{});
}

fn read(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const playlist = id(req, "id") catch |err| return api.failure(res, err);
    const user = auth.optionalUser(app, req, res.arena) catch |err| return api.failure(res, err);
    api.jsonText(res, repository.read(app.db, res.arena, playlist, user) catch |err| return api.failure(res, err));
}

fn update(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const playlist = id(req, "id") catch |err| return api.failure(res, err);
    const input = (try api.json(req, res, model.CreatePlaylist)) orelse return;
    const user = auth.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    service.update(app, res.arena, user, playlist, input) catch |err| return api.failure(res, err);
    res.status = 204;
    res.header("Cache-Control", "no-store");
}

fn member(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const playlist = id(req, "id") catch |err| return api.failure(res, err);
    const target = id(req, "user_id") catch |err| return api.failure(res, err);
    const input = (try api.json(req, res, struct { role: model.Role })) orelse return;
    const user = auth.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    repository.membership(app.db, res.arena, playlist, user, target, @tagName(input.role)) catch |err| return api.failure(res, err);
    res.status = 204;
    res.header("Cache-Control", "no-store");
}

fn removeMember(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const playlist = id(req, "id") catch |err| return api.failure(res, err);
    const target = id(req, "user_id") catch |err| return api.failure(res, err);
    const user = auth.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    repository.membership(app.db, res.arena, playlist, user, target, null) catch |err| return api.failure(res, err);
    res.status = 204;
    res.header("Cache-Control", "no-store");
}

fn addTrack(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    try changeTrack(app, req, res, true);
}

fn removeTrack(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    try changeTrack(app, req, res, false);
}

fn changeTrack(app: *App, req: *httpz.Request, res: *httpz.Response, add: bool) !void {
    const playlist = id(req, "id") catch |err| return api.failure(res, err);
    const track = id(req, "track_id") catch |err| return api.failure(res, err);
    const user = auth.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    repository.track(app.db, res.arena, playlist, user, track, add) catch |err| return api.failure(res, err);
    res.status = 204;
    res.header("Cache-Control", "no-store");
}

fn shareLink(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const playlist = id(req, "id") catch |err| return api.failure(res, err);
    const user = auth.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    const token = service.createLink(app, res.arena, user, playlist) catch |err| return api.failure(res, err);
    res.header("Cache-Control", "no-store");
    try res.json(.{ .path = try std.fmt.allocPrint(res.arena, "/api/shared/playlists/{s}", .{&token}) }, .{});
}

fn revokeLink(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const playlist = id(req, "id") catch |err| return api.failure(res, err);
    const user = auth.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    repository.link(app.db, res.arena, playlist, user, null) catch |err| return api.failure(res, err);
    res.status = 204;
    res.header("Cache-Control", "no-store");
}

fn shared(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const token = req.param("token") orelse return api.failure(res, error.NotFound);
    if (!tokens.validToken(token)) return api.failure(res, error.NotFound);
    const hash = tokens.tokenHash(token);
    res.header("Referrer-Policy", "no-referrer");
    api.jsonText(res, repository.readShared(app.db, res.arena, &hash) catch |err| return api.failure(res, err));
}

fn image(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const playlist = id(req, "id") catch |err| return api.failure(res, err);
    const data = req.body() orelse return api.failure(res, error.EmptyImage);
    if (data.len == 0) return api.failure(res, error.EmptyImage);
    if (data.len > 5 * 1024 * 1024) return api.failure(res, error.ImageTooLarge);
    const header = req.header("content-type") orelse return api.failure(res, error.UnsupportedMediaType);
    const end = std.mem.indexOfScalar(u8, header, ';') orelse header.len;
    const mime = try std.ascii.allocLowerString(res.arena, std.mem.trim(u8, header[0..end], " \t"));
    if (!std.mem.eql(u8, mime, "image/png") and !std.mem.eql(u8, mime, "image/jpeg") and !std.mem.eql(u8, mime, "image/webp")) return api.failure(res, error.UnsupportedMediaType);
    if (req.header("content-encoding")) |encoding| {
        if (!std.ascii.eqlIgnoreCase(encoding, "identity")) return api.failure(res, error.UnsupportedContentEncoding);
    }
    const user = auth.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    const key = service.image(app, res.arena, user, playlist, mime, data) catch |err| return api.failure(res, err);
    res.header("Cache-Control", "no-store");
    try res.json(.{ .image_key = key, .bucket = app.storage.bucket }, .{});
}

test "playlist creation and updates require a session" {
    var app: App = .{ .db = undefined, .storage = undefined, .max_upload_bytes = 1024 };
    var context = httpz.testing.init(.{});
    defer context.deinit();
    context.header("content-type", "application/json");
    context.body("{\"title\":\"Playlist\"}");
    try create(&app, context.req, context.res);
    try context.expectStatus(401);
}

test "image validation preserves HTTP errors before authorization or storage" {
    var app: App = .{ .db = undefined, .storage = undefined, .max_upload_bytes = 64 * 1024 * 1024 };
    const oversized = try std.testing.allocator.alloc(u8, 5 * 1024 * 1024 + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'a');
    const Case = struct { body: []const u8 = "image", mime: ?[]const u8 = "image/png", encoding: ?[]const u8 = null, status: u16, code: []const u8 };
    for ([_]Case{
        .{ .body = "", .status = 400, .code = "empty_image" },
        .{ .body = oversized, .status = 413, .code = "image_too_large" },
        .{ .mime = null, .status = 415, .code = "unsupported_media_type" },
        .{ .mime = "image/svg+xml", .status = 415, .code = "unsupported_media_type" },
        .{ .encoding = "gzip", .status = 415, .code = "unsupported_content_encoding" },
    }) |case| {
        var context = httpz.testing.init(.{});
        defer context.deinit();
        context.param("id", "11111111-1111-4111-8111-111111111111");
        if (case.mime) |value| context.header("content-type", value);
        if (case.encoding) |value| context.header("content-encoding", value);
        context.body(case.body);
        try image(&app, context.req, context.res);
        try context.expectStatus(case.status);
        try context.expectJson(.{ .@"error" = case.code });
        try context.expectHeader("Cache-Control", "no-store");
    }
}

test "missing or malformed share tokens return not_found without DB access" {
    var app: App = .{ .db = undefined, .storage = undefined, .max_upload_bytes = 1024 };
    for ([_]?[]const u8{ null, "bad-token" }) |token| {
        var context = httpz.testing.init(.{});
        defer context.deinit();
        if (token) |value| context.param("token", value);
        try shared(&app, context.req, context.res);
        try context.expectStatus(404);
        try context.expectJson(.{ .@"error" = "not_found" });
    }
}
