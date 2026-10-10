const std = @import("std");
const httpz = @import("httpz");
const Database = @import("infrastructure/database.zig").Database;
const S3 = @import("infrastructure/s3.zig").S3;
const api = @import("helpers/api.zig");

/// Общие ресурсы и настройки HTTP-обработчиков и фоновых задач.
/// После первого обращения к S3 структура должна оставаться по стабильному адресу.
/// Строки настроек должны жить до остановки приложения.
pub const App = struct {
    /// Пул БД; освобождается после остановки всех обработчиков и фоновых задач.
    db: Database,
    /// Общий S3-клиент с пулом HTTP-соединений.
    storage: S3,

    /// Максимальный размер тела запроса и загружаемого файла в байтах.
    max_upload_bytes: usize,

    ffmpeg_path: []const u8 = "ffmpeg",
    ytdlp_path: []const u8 = "yt-dlp",

    spotify_tmp_dir: []const u8 = "/tmp/musica-spotify",
    spotify_timeout_seconds: u32 = 900,

    hls_tmp_dir: []const u8 = "/tmp/musica-hls",
    hls_timeout_seconds: u32 = 900,

    cookie_secure: bool = false,
    registration_enabled: bool = false,

    /// Срок хранения общего трека без ссылок из пользовательских плейлистов.
    shared_track_retention_seconds: u32 = 7 * 24 * 60 * 60,

    /// Возвращает стандартный ответ API для неизвестного маршрута.
    pub fn notFound(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
        try api.failure(res, error.NotFound);
    }

    /// Логирует необработанную ошибку запроса и возвращает 500 без внутренних подробностей.
    pub fn uncaughtError(
        _: *App,
        _: *httpz.Request,
        res: *httpz.Response,
        err: anyerror,
    ) void {
        std.log.err("Unhandled request error: {s}", .{@errorName(err)});

        res.status = 500;
        res.content_type = .JSON;
        res.body = "{\"error\":\"internal_error\"}";
        res.header("Cache-Control", "no-store");
    }
};
