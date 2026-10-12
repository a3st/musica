const httpz = @import("httpz");
const App = @import("../../app.zig").App;
const api = @import("../../helpers/api.zig");
const auth_service = @import("../auth/service.zig");
const auth_routes = @import("../auth/routes.zig");
const model = @import("model.zig");
const service = @import("service.zig");

/// Регистрирует чтение профиля и чувствительные операции над собственным аккаунтом.
pub fn register(router: *httpz.Router(*App, httpz.Action(*App))) void {
    router.get("/api/users/me", read, .{});
    router.put("/api/profile/password", changePassword, .{});
    router.delete("/api/profile", remove, .{});
}

/// Возвращает собственный профиль после проверки действующей сессии.
fn read(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);

    api.sendJsonText(res, service.read(&app.db, res.arena, user) catch |err| return api.failure(res, err));
}

/// Меняет пароль после проверки сессии и текущего пароля; сбрасывает cookie.
fn changePassword(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    const input = (try api.readJson(req, res, model.ChangePassword)) orelse return;
    service.changePassword(app, res.arena, user, input) catch |err| return api.failure(res, err);

    res.status = 204;
    res.header("Cache-Control", "no-store");
    try auth_routes.setSessionCookie(app, res, "", true);
}

/// Удаляет собственный аккаунт после явного подтверждения паролем.
fn remove(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    const input = (try api.readJson(req, res, model.Confirmation)) orelse return;
    service.remove(app, res.arena, user, input) catch |err| return api.failure(res, err);

    res.status = 204;
    res.header("Cache-Control", "no-store");
    try auth_routes.setSessionCookie(app, res, "", true);
}

test "profile endpoints reject anonymous requests before reading passwords or acquiring a connection" {
    var app: App = undefined;
    inline for (.{ read, changePassword, remove }) |handler| {
        var context = httpz.testing.init(.{});
        defer context.deinit();

        try handler(&app, context.req, context.res);
        try context.expectStatus(401);
        try context.expectJson(.{ .@"error" = "unauthorized" });
    }
}
