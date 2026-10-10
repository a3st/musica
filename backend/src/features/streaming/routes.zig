const std = @import("std");
const httpz = @import("httpz");
const App = @import("../../app.zig").App;
const api = @import("../../helpers/api.zig");
const auth_service = @import("../auth/service.zig");
const auth_model = @import("../auth/model.zig");
const tracks_model = @import("../tracks/model.zig");
const model = @import("model.zig");
const service = @import("service.zig");

/// Регистрирует маршруты подготовки HLS, состояния, манифеста и сегментов.
pub fn register(router: *httpz.Router(*App, httpz.Action(*App))) void {
    router.post("/api/tracks/:id/hls", prepare, .{});
    router.get("/api/tracks/:id/hls/status", status, .{});
    router.get("/api/tracks/:id/hls/index.m3u8", manifest, .{});
    router.get("/api/tracks/:id/hls/segments/:segment", segment, .{});
}

/// Читает UUID трека из маршрута; отсутствие или неверный формат — InvalidTrackId.
fn requireTrackId(req: *httpz.Request) ![]const u8 {
    const id = req.param("id") orelse return error.InvalidTrackId;
    if (!tracks_model.isValidId(id)) return error.InvalidTrackId;
    return id;
}

/// Читает необязательный share_token из query; неверный токен — NotFound.
fn readShareToken(req: *httpz.Request) !?[]const u8 {
    const query = req.query() catch return error.InvalidInput;

    const token = query.get("share_token") orelse return null;
    if (!auth_model.isValidToken(token)) return error.NotFound;

    return token;
}

/// Проверяет доступ через сессию или ссылку и возвращает состояние стриминга трека.
fn readAccessibleState(app: *App, req: *httpz.Request, res: *httpz.Response) !model.State {
    const id = try requireTrackId(req);

    const user = try auth_service.optionalUser(app, req, res.arena);

    const token = try readShareToken(req);

    const hash = if (token) |value| auth_model.tokenHash(value) else null;

    return service.read(&app.db, res.arena, id, user, if (hash) |*value| value else null);
}

/// Ставит подготовку HLS в очередь; возвращает 200 для готового трека, иначе 202.
fn prepare(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = requireTrackId(req) catch |err| return api.failure(res, err);

    const user = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);

    const state = service.enqueue(&app.db, res.arena, id, user) catch |err| return api.failure(res, err);

    res.status = if (state.status == .streamed) 200 else 202;
    res.header("Cache-Control", "no-store");

    try res.json(.{ .status = state.status, .preparation = state.preparation }, .{});
}

/// Возвращает состояние трека и задачи подготовки HLS с проверкой доступа.
fn status(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const state = readAccessibleState(app, req, res) catch |err| return api.failure(res, err);
    res.header("Cache-Control", "no-store");

    try res.json(.{ .status = state.status, .preparation = state.preparation }, .{});
}

/// Возвращает HLS-манифест с адресами сегментов и токеном ссылки, если он передан.
fn manifest(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const state = readAccessibleState(app, req, res) catch |err| return api.failure(res, err);
    const source = service.readObject(
        app,
        res.arena,
        state,
        "index.m3u8",
        model.max_manifest_bytes,
    ) catch |err| return api.failure(res, err);

    res.body = try model.buildPlaybackManifest(res.arena, source, try readShareToken(req));
    res.header("Content-Type", "application/vnd.apple.mpegurl");
    res.header("Cache-Control", "no-store");
}

/// Проверяет имя, номер сегмента и доступ к треку, затем возвращает MPEG-TS из S3.
fn segment(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("segment") orelse return api.failure(res, error.NotFound);
    const index = model.parseSegmentIndex(name) orelse return api.failure(res, error.NotFound);
    const state = readAccessibleState(app, req, res) catch |err| return api.failure(res, err);
    if (state.status != .streamed) return api.failure(res, error.HlsNotReady);
    if (index >= (state.segments orelse return error.DatabaseUnavailable)) return api.failure(res, error.NotFound);

    res.body = service.readObject(app, res.arena, state, name, model.max_segment_bytes) catch |err| return api.failure(res, err);
    res.header("Content-Type", "video/mp2t");
    res.header("Cache-Control", "no-store");
}

test "HLS routes validate IDs and segment names before accessing dependencies" {
    var app: App = undefined;
    app.max_upload_bytes = 1024;
    var bad_id = httpz.testing.init(.{});
    defer bad_id.deinit();
    bad_id.param("id", "../secret");
    try prepare(&app, bad_id.req, bad_id.res);

    try bad_id.expectStatus(400);

    var traversal = httpz.testing.init(.{});
    defer traversal.deinit();
    traversal.param("segment", "../source");
    try segment(&app, traversal.req, traversal.res);

    try traversal.expectStatus(404);

    var private = httpz.testing.init(.{});
    defer private.deinit();
    private.param("id", "11111111-1111-4111-8111-111111111111");
    try prepare(&app, private.req, private.res);

    try private.expectStatus(401);
}
