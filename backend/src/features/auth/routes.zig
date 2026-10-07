const httpz = @import("httpz");
const App = @import("../../app.zig").App;
const api = @import("../../helpers/api.zig");
const model = @import("model.zig");
const service = @import("service.zig");
const repository = @import("repository.zig");

pub fn register(router: *httpz.Router(*App, httpz.Action(*App))) void {
    router.post("/api/auth/register", signup, .{});
    router.post("/api/auth/login", login, .{});
    router.post("/api/auth/logout", logout, .{});
    router.get("/api/users/me", me, .{});
}

fn signup(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const input = (try api.json(req, res, model.Credentials)) orelse return;
    const result = service.register(app, res.arena, input) catch |err| return api.failure(res, err);
    res.status = 201;
    res.header("Cache-Control", "no-store");
    try res.json(.{ .user_id = result.user_id, .token = &result.token, .token_type = "Bearer", .expires_in = 30 * 24 * 60 * 60 }, .{});
}

fn login(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const input = (try api.json(req, res, model.Credentials)) orelse return;
    const result = service.login(app, res.arena, input) catch |err| return api.failure(res, err);
    res.header("Cache-Control", "no-store");
    try res.json(.{ .user_id = result.user_id, .token = &result.token, .token_type = "Bearer", .expires_in = 30 * 24 * 60 * 60 }, .{});
}

fn logout(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    const hash = model.tokenHash(try service.bearer(req));
    repository.logout(app.db, &hash) catch |err| return api.failure(res, err);
    res.status = 204;
    res.header("Cache-Control", "no-store");
}

fn me(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const user = service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    api.jsonText(res, repository.me(app.db, res.arena, user) catch |err| return api.failure(res, err));
}
