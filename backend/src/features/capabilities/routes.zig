const httpz = @import("httpz");
const App = @import("../../app.zig").App;

/// Регистрирует публичный маршрут возможностей сервера для настройки интерфейса.
pub fn register(router: *httpz.Router(*App, httpz.Action(*App))) void {
    router.get("/api/capabilities", read, .{});
}

/// Возвращает действующие флаги без обращения к БД; ответ не кешируется.
fn read(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.header("Cache-Control", "no-store");

    try res.json(app.capabilities, .{});
}

test "capabilities are available without a session or database access" {
    var app: App = undefined;
    app.capabilities = .{ .web_search = false, .spotify_import = false };
    var context = httpz.testing.init(.{});
    defer context.deinit();

    try read(&app, context.req, context.res);
    try context.expectStatus(200);
    try context.expectJson(.{ .web_search = false, .spotify_import = false });
    try context.expectHeader("Cache-Control", "no-store");
}
