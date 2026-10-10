const httpz = @import("httpz");
const App = @import("../../app.zig").App;

/// Регистрирует маршрут проверки доступности HTTP-сервера.
pub fn register(router: *httpz.Router(*App, httpz.Action(*App))) void {
    router.get("/api/health", health, .{});
}

/// Возвращает состояние сервиса без обращения к БД и хранилищу.
fn health(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.header("Cache-Control", "no-store");

    try res.json(.{ .status = "ok", .service = "musica" }, .{});
}
