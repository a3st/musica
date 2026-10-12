const httpz = @import("httpz");
const App = @import("../../app.zig").App;
const api = @import("../../helpers/api.zig");
const auth_service = @import("../auth/service.zig");
const service = @import("service.zig");
const users_model = @import("../users/model.zig");
const tracks_model = @import("../tracks/model.zig");

/// Регистрирует операции хранилища; каждый сервис проверяет административную роль.
pub fn register(router: *httpz.Router(*App, httpz.Action(*App))) void {
    router.get("/api/admin/users", listUsers, .{});
    router.post("/api/admin/users", createUser, .{});
    router.delete("/api/admin/users/:id", removeUser, .{});
    router.get("/api/admin/storage", readStorage, .{});
    router.post("/api/admin/storage/cleanup-orphaned", cleanupOrphaned, .{});
}

/// Возвращает список пользователей без учётных секретов.
fn listUsers(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    api.sendJsonText(res, service.listUsers(app, res.arena, user) catch |err| return api.failure(res, err));
}

/// Создаёт обычную учётку и дефолтный Uploads; сохраняет прежний контракт POST /admin/users.
fn createUser(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    const input = (try api.readJson(req, res, users_model.CreateUser)) orelse return;
    const id = service.createUser(app, res.arena, user, input) catch |err| return api.failure(res, err);
    res.status = 201;
    res.header("Cache-Control", "no-store");
    try res.json(.{ .id = id }, .{});
}

/// Удаляет выбранную учётку после проверки административной роли.
fn removeUser(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    const id = req.param("id").?;
    if (!tracks_model.isValidId(id)) return api.failure(res, error.InvalidInput);
    service.removeUser(app, res.arena, user, id) catch |err| return api.failure(res, err);
    res.status = 204;
    res.header("Cache-Control", "no-store");
}

/// Возвращает размеры зарегистрированных исходников и счётчики обработки.
fn readStorage(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    const result = service.readStorage(app, res.arena, user) catch |err| return api.failure(res, err);
    res.header("Cache-Control", "no-store");
    try res.json(result, .{});
}

/// Выполняет один пакет ручной очистки orphaned-треков.
fn cleanupOrphaned(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    const result = service.cleanupOrphaned(app, res.arena, user) catch |err| return api.failure(res, err);
    res.header("Cache-Control", "no-store");
    try res.json(result, .{});
}

test "admin endpoints reject anonymous requests before touching storage or database" {
    var app: App = undefined;
    inline for (.{ readStorage, listUsers, cleanupOrphaned }) |handler| {
        var context = httpz.testing.init(.{});
        defer context.deinit();

        try handler(&app, context.req, context.res);
        try context.expectStatus(401);
        try context.expectJson(.{ .@"error" = "unauthorized" });
    }
}
