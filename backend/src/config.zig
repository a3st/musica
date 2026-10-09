const std = @import("std");
const database = @import("infrastructure/database.zig");
const s3 = @import("infrastructure/s3.zig");

pub const Config = struct {
    http_address: std.Io.net.IpAddress,
    database: database.Settings,
    s3: s3.Settings,
    max_upload_bytes: usize,
    ffmpeg_path: []const u8,
    ytdlp_path: []const u8,
    spotify_tmp_dir: []const u8,
    spotify_worker_enabled: bool,
    spotify_timeout_seconds: u32,
    hls_tmp_dir: []const u8,
    hls_worker_enabled: bool,
    hls_timeout_seconds: u32,
    cookie_secure: bool,

    pub fn load(env: *const std.process.Environ.Map) !Config {
        const config: Config = .{
            .http_address = try httpAddress(env),
            .database = try database.Settings.load(env),
            .s3 = try s3.Settings.load(env),
            .max_upload_bytes = try std.fmt.parseInt(usize, env.get("MAX_UPLOAD_BYTES") orelse "67108864", 10),
            .ffmpeg_path = env.get("FFMPEG_PATH") orelse "ffmpeg",
            .ytdlp_path = env.get("YTDLP_PATH") orelse "yt-dlp",
            .spotify_tmp_dir = env.get("SPOTIFY_TMP_DIR") orelse env.get("TEMP") orelse "/tmp/musica-spotify",
            .spotify_worker_enabled = try boolean(env.get("SPOTIFY_WORKER_ENABLED") orelse "true"),
            .spotify_timeout_seconds = try std.fmt.parseInt(u32, env.get("SPOTIFY_TIMEOUT_SECONDS") orelse "900", 10),
            .hls_tmp_dir = env.get("HLS_TMP_DIR") orelse env.get("TEMP") orelse "/tmp/musica-hls",
            .hls_worker_enabled = try boolean(env.get("HLS_WORKER_ENABLED") orelse "true"),
            .hls_timeout_seconds = try std.fmt.parseInt(u32, env.get("HLS_TIMEOUT_SECONDS") orelse "900", 10),
            .cookie_secure = try boolean(env.get("AUTH_COOKIE_SECURE") orelse "false"),
        };
        if (config.max_upload_bytes == 0 or config.max_upload_bytes > 512 * 1024 * 1024)
            return error.InvalidConfiguration;
        if (config.ytdlp_path.len == 0 or config.spotify_tmp_dir.len == 0 or config.spotify_timeout_seconds == 0 or config.spotify_timeout_seconds > 3600)
            return error.InvalidConfiguration;
        if (config.ffmpeg_path.len == 0 or config.hls_tmp_dir.len == 0 or config.hls_timeout_seconds == 0 or config.hls_timeout_seconds > 3600)
            return error.InvalidConfiguration;
        return config;
    }
};

fn boolean(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidConfiguration;
}

fn httpAddress(env: *const std.process.Environ.Map) !std.Io.net.IpAddress {
    const port = try std.fmt.parseInt(u16, env.get("HTTP_PORT") orelse "8080", 10);
    if (port == 0) return error.InvalidConfiguration;
    return std.Io.net.IpAddress.parse(env.get("HTTP_HOST") orelse "127.0.0.1", port) catch
        error.InvalidConfiguration;
}
