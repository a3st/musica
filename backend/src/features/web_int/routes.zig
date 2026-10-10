const httpz = @import("httpz");
const App = @import("../../app.zig").App;
const api = @import("../../helpers/api.zig");
const auth_service = @import("../auth/service.zig");
const model = @import("model.zig");
const service = @import("service.zig");

/// Регистрирует поиск в каталоге iTunes и добавление результата в Uploads.
pub fn register(router: *httpz.Router(*App, httpz.Action(*App))) void {
    router.get("/api/web/search", search, .{});
    router.post("/api/web/tracks", create, .{});
}

/// Возвращает метаданные каталога; поиск не скачивает аудио.
fn search(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    const params = req.query() catch return api.failure(res, error.InvalidInput);
    const query = params.get("q") orelse return api.failure(res, error.InvalidInput);
    const tracks = service.search(app, res.arena, query) catch |err| return api.failure(res, err);

    res.header("Cache-Control", "no-store");
    try res.json(.{ .tracks = tracks }, .{});
}

/// Проверяет выбранный ID через iTunes и ставит существующую задачу скачивания.
fn create(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    const input = (try api.readJsonWithOptions(req, res, model.Selection, .{ .max_bytes = 1024 })) orelse return;
    const id = service.addToLibrary(app, res.arena, user, input) catch |err| return api.failure(res, err);

    res.status = 202;
    res.header("Cache-Control", "no-store");
    try res.json(.{ .id = id }, .{});
}

test "Web search and download require a session before accessing the catalog" {
    const Action = *const fn (*App, *httpz.Request, *httpz.Response) anyerror!void;
    for ([_]Action{ search, create }) |action| {
        var app: App = undefined;
        app.max_upload_bytes = 1024;
        var context = httpz.testing.init(.{});
        defer context.deinit();

        try action(&app, context.req, context.res);
        try context.expectStatus(401);
    }
}
