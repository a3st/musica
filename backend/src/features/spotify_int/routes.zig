const httpz = @import("httpz");
const App = @import("../../app.zig").App;
const model = @import("model.zig");
const service = @import("service.zig");
const auth_service = @import("../auth/service.zig");
const tracks_model = @import("../tracks/model.zig");
const api = @import("../../helpers/api.zig");

pub fn register(router: *httpz.Router(*App, httpz.Action(*App))) void {
    router.post("/api/spotify/import", create, .{});
    router.get("/api/spotify/imports/:id", status, .{});
    router.post("/api/spotify/imports/:id/retry", retry, .{});
}

fn create(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    const input = (try api.jsonOpts(req, res, model.Import, .{ .max_bytes = model.max_json_bytes })) orelse return;
    const result = service.create(app, res.arena, user, input) catch |err| return api.failure(res, err);
    res.status = 202;
    res.header("Cache-Control", "no-store");
    try res.json(result, .{});
}

fn status(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    const id = req.param("id") orelse return api.failure(res, error.InvalidInput);
    if (!tracks_model.validId(id)) return api.failure(res, error.InvalidInput);
    const body = service.status(&app.db, res.arena, user, id) catch |err| return api.failure(res, err);
    api.jsonText(res, body);
}

fn retry(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    const id = req.param("id") orelse return api.failure(res, error.InvalidInput);
    if (!tracks_model.validId(id)) return api.failure(res, error.InvalidInput);
    const body = service.retry(&app.db, res.arena, user, id) catch |err| return api.failure(res, err);
    api.jsonText(res, body);
}

test "Spotify import requires a session before accessing storage" {
    var app: App = .{ .db = undefined, .storage = undefined, .max_upload_bytes = 1024 };
    var context = httpz.testing.init(.{});
    defer context.deinit();
    context.header("content-type", "application/json");
    context.body("{}");
    try create(&app, context.req, context.res);
    try context.expectStatus(401);
}
