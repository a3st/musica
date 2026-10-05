const httpz = @import("httpz");
const App = @import("../../app.zig").App;

pub fn register(router: *httpz.Router(*App, httpz.Action(*App))) void {
    router.get("/api/health", health, .{});
}

fn health(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.header("Cache-Control", "no-store");
    try res.json(.{ .status = "ok", .service = "musica" }, .{});
}
