const std = @import("std");

pub const Config = struct {
    http_address: std.Io.net.IpAddress,
    pg_host: []const u8,
    pg_port: u16,
    pg_database: []const u8,
    pg_user: []const u8,
    pg_password: []const u8,
    s3_endpoint: []const u8,
    s3_region: []const u8,
    s3_bucket: []const u8,
    s3_access_key: []const u8,
    s3_secret_key: []const u8,
    max_upload_bytes: usize,
    ffmpeg_path: []const u8,
    hls_tmp_dir: []const u8,
    hls_worker_enabled: bool,
    hls_timeout_seconds: u32,

    pub fn load(env: *const std.process.Environ.Map) !Config {
        const config: Config = .{
            .http_address = try httpAddress(env),
            .pg_host = env.get("PGHOST") orelse "127.0.0.1",
            .pg_port = try std.fmt.parseInt(u16, env.get("PGPORT") orelse "5432", 10),
            .pg_database = env.get("PGDATABASE") orelse "musica",
            .pg_user = env.get("PGUSER") orelse "musica",
            .pg_password = try required(env, "PGPASSWORD"),
            .s3_endpoint = std.mem.trimEnd(u8, env.get("S3_ENDPOINT") orelse "http://127.0.0.1:9000", "/"),
            .s3_region = env.get("S3_REGION") orelse "us-east-1",
            .s3_bucket = env.get("S3_BUCKET") orelse "uploads",
            .s3_access_key = try required(env, "S3_ACCESS_KEY_ID"),
            .s3_secret_key = try required(env, "S3_SECRET_ACCESS_KEY"),
            .max_upload_bytes = try std.fmt.parseInt(usize, env.get("MAX_UPLOAD_BYTES") orelse "67108864", 10),
            .ffmpeg_path = env.get("FFMPEG_PATH") orelse "ffmpeg",
            .hls_tmp_dir = env.get("HLS_TMP_DIR") orelse env.get("TEMP") orelse "/tmp/musica-hls",
            .hls_worker_enabled = try boolean(env.get("HLS_WORKER_ENABLED") orelse "true"),
            .hls_timeout_seconds = try std.fmt.parseInt(u32, env.get("HLS_TIMEOUT_SECONDS") orelse "900", 10),
        };
        if (config.pg_port == 0 or config.max_upload_bytes == 0 or config.max_upload_bytes > 512 * 1024 * 1024)
            return error.InvalidConfiguration;
        if (config.pg_host.len == 0 or config.pg_user.len == 0 or config.pg_database.len == 0)
            return error.InvalidConfiguration;
        if (config.ffmpeg_path.len == 0 or config.hls_tmp_dir.len == 0 or config.hls_timeout_seconds == 0 or config.hls_timeout_seconds > 3600)
            return error.InvalidConfiguration;
        try validateEndpoint(config.s3_endpoint);
        if (config.s3_bucket.len < 3 or config.s3_bucket.len > 63 or
            !std.ascii.isAlphanumeric(config.s3_bucket[0]) or
            !std.ascii.isAlphanumeric(config.s3_bucket[config.s3_bucket.len - 1]))
            return error.InvalidConfiguration;
        for (config.s3_bucket) |c| {
            if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-'))
                return error.InvalidConfiguration;
        }
        for (config.s3_region) |c| {
            if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-'))
                return error.InvalidConfiguration;
        }
        if (config.s3_region.len == 0) return error.InvalidConfiguration;
        for (config.s3_access_key) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return error.InvalidConfiguration;
        }
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

fn required(env: *const std.process.Environ.Map, name: []const u8) ![]const u8 {
    const value = env.get(name) orelse {
        std.log.err("Missing environment variable: {s}", .{name});
        return error.MissingConfiguration;
    };
    if (value.len == 0) return error.InvalidConfiguration;
    return value;
}

pub fn validateEndpoint(endpoint: []const u8) !void {
    const uri = std.Uri.parse(endpoint) catch return error.InvalidConfiguration;
    if ((!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) or
        uri.host == null or uri.user != null or uri.password != null or
        uri.query != null or uri.fragment != null or uri.path.percent_encoded.len != 0)
        return error.InvalidConfiguration;
    for (endpoint) |c| {
        if (c <= 32 or c >= 127) return error.InvalidConfiguration;
    }
}

test "reject endpoint credentials, paths and query strings" {
    try validateEndpoint("http://127.0.0.1:9000");
    try validateEndpoint("https://minio.example.com");
    try std.testing.expectError(error.InvalidConfiguration, validateEndpoint("http://user:pass@localhost:9000"));
    try std.testing.expectError(error.InvalidConfiguration, validateEndpoint("http://localhost:9000/proxy"));
    try std.testing.expectError(error.InvalidConfiguration, validateEndpoint("http://localhost:9000?x=1"));
}
