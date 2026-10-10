const httpz = @import("httpz");
const App = @import("../../app.zig").App;
const api = @import("../../helpers/api.zig");
const auth_model = @import("../auth/model.zig");
const auth_service = @import("../auth/service.zig");
const service = @import("service.zig");

/// Регистрирует административный маршрут создания пользователей.
pub fn register(router: *httpz.Router(*App, httpz.Action(*App))) void {
    router.post("/api/admin/users", create, .{});
}

/// Создаёт пользователя от имени администратора; возвращает его ID и статус 201.
fn create(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);

    const input = (try api.readJson(req, res, auth_model.Credentials)) orelse return;
    const id = service.create(app, res.arena, user, input) catch |err| return api.failure(res, err);

    res.status = 201;
    res.header("Cache-Control", "no-store");

    try res.json(.{ .id = id }, .{});
}
