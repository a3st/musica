const std = @import("std");
const database = @import("infrastructure/database.zig");
const s3 = @import("infrastructure/s3.zig");

/// Настройки запуска; строковые значения ссылаются на переданную карту окружения.
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
    registration_enabled: bool,
    bootstrap_admin_username: ?[]const u8,
    bootstrap_admin_password: ?[]const u8,

    shared_track_retention_seconds: u32,

    /// Читает окружение, подставляет значения по умолчанию и проверяет ограничения.
    /// Учётные данные стартового администратора должны быть заданы вместе; пустая пара отключает создание.
    pub fn load(env: *const std.process.Environ.Map) !Config {
        const admin_username = env.get("BOOTSTRAP_ADMIN_USERNAME") orelse "";
        const admin_password = env.get("BOOTSTRAP_ADMIN_PASSWORD") orelse "";

        const config: Config = .{
            .http_address = try loadHttpAddress(env),
            .database = try database.Settings.load(env),
            .s3 = try s3.Settings.load(env),

            .max_upload_bytes = try std.fmt.parseInt(usize, env.get("MAX_UPLOAD_BYTES") orelse "67108864", 10),
            .ffmpeg_path = env.get("FFMPEG_PATH") orelse "ffmpeg",
            .ytdlp_path = env.get("YTDLP_PATH") orelse "yt-dlp",

            .spotify_tmp_dir = env.get("SPOTIFY_TMP_DIR") orelse env.get("TEMP") orelse "/tmp/musica-spotify",
            .spotify_worker_enabled = try parseBoolean(env.get("SPOTIFY_WORKER_ENABLED") orelse "true"),
            .spotify_timeout_seconds = try std.fmt.parseInt(u32, env.get("SPOTIFY_TIMEOUT_SECONDS") orelse "900", 10),

            .hls_tmp_dir = env.get("HLS_TMP_DIR") orelse env.get("TEMP") orelse "/tmp/musica-hls",
            .hls_worker_enabled = try parseBoolean(env.get("HLS_WORKER_ENABLED") orelse "true"),
            .hls_timeout_seconds = try std.fmt.parseInt(u32, env.get("HLS_TIMEOUT_SECONDS") orelse "900", 10),

            .cookie_secure = try parseBoolean(env.get("AUTH_COOKIE_SECURE") orelse "false"),
            .registration_enabled = try parseBoolean(env.get("REGISTRATION_ENABLED") orelse "false"),
            .bootstrap_admin_username = if (admin_username.len > 0) admin_username else null,
            .bootstrap_admin_password = if (admin_password.len > 0) admin_password else null,

            .shared_track_retention_seconds = try std.fmt.parseInt(
                u32,
                env.get("SHARED_TRACK_RETENTION_SECONDS") orelse "604800",
                10,
            ),
        };

        if ((config.bootstrap_admin_username == null) != (config.bootstrap_admin_password == null))
            return error.InvalidConfiguration;

        if (config.max_upload_bytes == 0 or config.max_upload_bytes > 512 * 1024 * 1024)
            return error.InvalidConfiguration;

        if (config.ytdlp_path.len == 0 or config.spotify_tmp_dir.len == 0 or
            config.spotify_timeout_seconds == 0 or config.spotify_timeout_seconds > 3600)
            return error.InvalidConfiguration;

        if (config.ffmpeg_path.len == 0 or config.hls_tmp_dir.len == 0 or
            config.hls_timeout_seconds == 0 or config.hls_timeout_seconds > 3600)
            return error.InvalidConfiguration;

        return config;
    }
};

/// Принимает только строки "true" и "false"; иначе InvalidConfiguration.
fn parseBoolean(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;

    return error.InvalidConfiguration;
}

/// Читает HTTP_HOST и HTTP_PORT; проверяет IP-адрес и ненулевой порт.
fn loadHttpAddress(env: *const std.process.Environ.Map) !std.Io.net.IpAddress {
    const port = try std.fmt.parseInt(u16, env.get("HTTP_PORT") orelse "8080", 10);
    if (port == 0) return error.InvalidConfiguration;

    return std.Io.net.IpAddress.parse(env.get("HTTP_HOST") orelse "127.0.0.1", port) catch
        error.InvalidConfiguration;
}

test "bootstrap admin accepts an empty pair and rejects incomplete credentials" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try env.put("DB_PASSWORD", "fixture-db-password");
    try env.put("S3_ACCESS_KEY_ID", "fixture-access");
    try env.put("S3_SECRET_ACCESS_KEY", "fixture-secret");

    const absent = try Config.load(&env);
    try std.testing.expect(absent.bootstrap_admin_username == null);
    try std.testing.expect(absent.bootstrap_admin_password == null);

    try env.put("BOOTSTRAP_ADMIN_USERNAME", "");
    try env.put("BOOTSTRAP_ADMIN_PASSWORD", "");
    const empty = try Config.load(&env);
    try std.testing.expect(empty.bootstrap_admin_username == null);
    try std.testing.expect(empty.bootstrap_admin_password == null);

    try env.put("BOOTSTRAP_ADMIN_USERNAME", "fixture_admin");
    try std.testing.expectError(error.InvalidConfiguration, Config.load(&env));

    try env.put("BOOTSTRAP_ADMIN_USERNAME", "");
    try env.put("BOOTSTRAP_ADMIN_PASSWORD", "fixture-admin-password");
    try std.testing.expectError(error.InvalidConfiguration, Config.load(&env));

    try env.put("BOOTSTRAP_ADMIN_USERNAME", "fixture_admin");
    const configured = try Config.load(&env);
    try std.testing.expectEqualStrings("fixture_admin", configured.bootstrap_admin_username.?);
    try std.testing.expectEqualStrings("fixture-admin-password", configured.bootstrap_admin_password.?);
}
