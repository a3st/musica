const std = @import("std");
const httpz = @import("httpz");
const Database = @import("infrastructure/database.zig").Database;
const S3 = @import("infrastructure/s3.zig").S3;
const api = @import("helpers/api.zig");

pub const App = struct {
    db: Database,
    storage: S3,
    max_upload_bytes: usize,
    ffmpeg_path: []const u8 = "ffmpeg",
    ytdlp_path: []const u8 = "yt-dlp",
    spotify_tmp_dir: []const u8 = "/tmp/musica-spotify",
    spotify_timeout_seconds: u32 = 900,
    hls_tmp_dir: []const u8 = "/tmp/musica-hls",
    hls_timeout_seconds: u32 = 900,
    cookie_secure: bool = false,

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
