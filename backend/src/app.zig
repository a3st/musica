const std = @import("std");
const httpz = @import("httpz");
const pg = @import("pg");
const S3 = @import("infrastructure/s3.zig").S3;
const api = @import("helpers/api.zig");

pub const App = struct {
    db: *pg.Pool,
    storage: S3,
    max_upload_bytes: usize,

    pub fn notFound(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
        try api.failure(res, error.NotFound);
    }

    pub fn uncaughtError(_: *App, _: *httpz.Request, res: *httpz.Response, err: anyerror) void {
        std.log.err("Unhandled request error: {s}", .{@errorName(err)});
        res.status = 500;
        res.content_type = .JSON;
        res.body = "{\"error\":\"internal_error\"}";
        res.header("Cache-Control", "no-store");
    }
};
