const std = @import("std");
const httpz = @import("httpz");
const pg = @import("pg");
const S3 = @import("infrastructure/s3.zig").S3;

pub const App = struct {
    db: *pg.Pool,
    storage: S3,
    max_upload_bytes: usize,

    pub fn notFound(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
        try respondError(res, 404, "not_found");
    }

    pub fn uncaughtError(_: *App, _: *httpz.Request, res: *httpz.Response, err: anyerror) void {
        std.log.err("Unhandled request error: {s}", .{@errorName(err)});
        res.status = 500;
        res.content_type = .JSON;
        res.body = "{\"error\":\"internal_error\"}";
        res.header("Cache-Control", "no-store");
    }
};

pub fn respondError(res: *httpz.Response, status: u16, code: []const u8) !void {
    res.status = status;
    res.header("Cache-Control", "no-store");
    try res.json(.{ .@"error" = code }, .{});
}
