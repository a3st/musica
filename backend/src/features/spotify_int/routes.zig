const httpz = @import("httpz");
const App = @import("../../app.zig").App;
const model = @import("model.zig");
const service = @import("service.zig");
const auth_service = @import("../auth/service.zig");
const api = @import("../../helpers/api.zig");

/// Регистрирует маршрут импорта треков и плейлистов Spotify.
pub fn register(router: *httpz.Router(*App, httpz.Action(*App))) void {
    router.post("/api/spotify/import", create, .{});
}

/// Принимает данные импорта и ставит загрузки в очередь; возвращает 202 без ожидания файлов.
fn create(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);

    const input = (try api.readJsonWithOptions(req, res, model.Import, .{ .max_bytes = model.max_json_bytes })) orelse return;

    const result = service.create(app, res.arena, user, input) catch |err| return api.failure(res, err);

    res.status = 202;
    res.header("Cache-Control", "no-store");

    try res.json(result, .{});
}

test "Spotify import requires a session before accessing storage" {
    var app: App = undefined;
    app.max_upload_bytes = 1024;
    var context = httpz.testing.init(.{});
    defer context.deinit();
    context.header("content-type", "application/json");
    context.body("{}");
    try create(&app, context.req, context.res);

    try context.expectStatus(401);
}
