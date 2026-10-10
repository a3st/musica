const httpz = @import("httpz");
const App = @import("../../app.zig").App;
const api = @import("../../helpers/api.zig");
const auth_service = @import("../auth/service.zig");
const model = @import("model.zig");
const service = @import("service.zig");

/// Регистрирует общий поиск сервисных треков и каталога, скачивание и чтение состояния.
pub fn register(router: *httpz.Router(*App, httpz.Action(*App))) void {
    router.get("/api/web/search", search, .{});
    router.post("/api/web/tracks", create, .{});
    router.get("/api/web/tracks/:id", readPlayback, .{});
}

/// Возвращает состояние общего трека для ожидания воспроизведения без Uploads.
fn readPlayback(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    const id = req.param("id") orelse return api.failure(res, error.InvalidTrackId);
    const state = service.readPlayback(app, res.arena, id) catch |err| return api.failure(res, err);
    res.header("Cache-Control", "no-store");
    try res.json(state, .{});
}

/// Возвращает локальные сервисные треки и дополнительные результаты каталога; не скачивает аудио.
fn search(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    const params = req.query() catch return api.failure(res, error.InvalidInput);
    const query = params.get("q") orelse return api.failure(res, error.InvalidInput);
    const result = service.search(app, res.arena, query) catch |err| return api.failure(res, err);

    res.header("Cache-Control", "no-store");
    try res.json(result, .{});
}

/// Проверяет выбранный ID через iTunes и ставит существующую задачу скачивания.
fn create(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    const input = (try api.readJsonWithOptions(req, res, model.Selection, .{ .max_bytes = 1024 })) orelse return;
    const id = service.selectTrack(app, res.arena, user, input) catch |err| return api.failure(res, err);

    res.status = 202;
    res.header("Cache-Control", "no-store");
    try res.json(.{ .id = id }, .{});
}

test "Web search and download require a session before accessing the catalog" {
    const Action = *const fn (*App, *httpz.Request, *httpz.Response) anyerror!void;
    for ([_]Action{ search, create, readPlayback }) |action| {
        var app: App = undefined;
        app.max_upload_bytes = 1024;
        var context = httpz.testing.init(.{});
        defer context.deinit();

        try action(&app, context.req, context.res);
        try context.expectStatus(401);
    }
}
