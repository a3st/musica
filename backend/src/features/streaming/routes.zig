const std = @import("std");
const httpz = @import("httpz");
const App = @import("../../app.zig").App;
const api = @import("../../helpers/api.zig");
const auth_service = @import("../auth/service.zig");
const auth_model = @import("../auth/model.zig");
const tracks_model = @import("../tracks/model.zig");
const model = @import("model.zig");
const service = @import("service.zig");

pub fn register(router: *httpz.Router(*App, httpz.Action(*App))) void {
    router.post("/api/tracks/:id/hls", prepare, .{});
    router.get("/api/tracks/:id/hls/status", status, .{});
    router.get("/api/tracks/:id/hls/index.m3u8", manifest, .{});
    router.get("/api/tracks/:id/hls/segments/:segment", segment, .{});
}

fn trackId(req: *httpz.Request) ![]const u8 {
    const id = req.param("id") orelse return error.InvalidTrackId;
    if (!tracks_model.validId(id)) return error.InvalidTrackId;
    return id;
}

fn shareToken(req: *httpz.Request) !?[]const u8 {
    const query = req.query() catch return error.InvalidInput;
    const token = query.get("share_token") orelse return null;
    if (!auth_model.validToken(token)) return error.NotFound;
    return token;
}

fn accessible(app: *App, req: *httpz.Request, res: *httpz.Response) !model.State {
    const id = try trackId(req);
    const user = try auth_service.optionalUser(app, req, res.arena);
    const token = try shareToken(req);
    const hash = if (token) |value| auth_model.tokenHash(value) else null;
    return service.read(&app.db, res.arena, id, user, if (hash) |*value| value else null);
}

fn prepare(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = trackId(req) catch |err| return api.failure(res, err);
    const user = auth_service.requireUser(app, req, res.arena) catch |err| return api.failure(res, err);
    const state = service.enqueue(&app.db, res.arena, id, user) catch |err| return api.failure(res, err);
    res.status = if (state.status == .streamed) 200 else 202;
    res.header("Cache-Control", "no-store");
    try res.json(.{ .status = state.status, .preparation = state.preparation }, .{});
}

fn status(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const state = accessible(app, req, res) catch |err| return api.failure(res, err);
    res.header("Cache-Control", "no-store");
    try res.json(.{ .status = state.status, .preparation = state.preparation }, .{});
}

fn manifest(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const state = accessible(app, req, res) catch |err| return api.failure(res, err);
    const source = service.object(app, res.arena, state, "index.m3u8", model.max_manifest_bytes) catch |err| return api.failure(res, err);
    res.body = try model.playbackManifest(res.arena, source, try shareToken(req));
    res.header("Content-Type", "application/vnd.apple.mpegurl");
    res.header("Cache-Control", "no-store");
}

fn segment(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("segment") orelse return api.failure(res, error.NotFound);
    const index = model.segmentIndex(name) orelse return api.failure(res, error.NotFound);
    const state = accessible(app, req, res) catch |err| return api.failure(res, err);
    if (state.status != .streamed) return api.failure(res, error.HlsNotReady);
    if (index >= (state.segments orelse return error.DatabaseUnavailable)) return api.failure(res, error.NotFound);
    res.body = service.object(app, res.arena, state, name, model.max_segment_bytes) catch |err| return api.failure(res, err);
    res.header("Content-Type", "video/mp2t");
    res.header("Cache-Control", "no-store");
}

test "HLS routes validate IDs and segment names before accessing dependencies" {
    var app: App = .{ .db = undefined, .storage = undefined, .max_upload_bytes = 1024 };
    var bad_id = httpz.testing.init(.{});
    defer bad_id.deinit();
    bad_id.param("id", "../secret");
    try prepare(&app, bad_id.req, bad_id.res);
    try bad_id.expectStatus(400);
    var traversal = httpz.testing.init(.{});
    defer traversal.deinit();
    traversal.param("segment", "../source");
    try segment(&app, traversal.req, traversal.res);
    try traversal.expectStatus(404);
    var private = httpz.testing.init(.{});
    defer private.deinit();
    private.param("id", "11111111-1111-4111-8111-111111111111");
    try prepare(&app, private.req, private.res);
    try private.expectStatus(401);
}
