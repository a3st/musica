const std = @import("std");
const httpz = @import("httpz");
const Database = @import("infrastructure/database.zig").Database;
const S3 = @import("infrastructure/s3.zig").S3;
const Catalog = @import("infrastructure/catalog/catalog.zig").Catalog;
const Probe = @import("infrastructure/media/probe.zig").Probe;
const FFmpeg = @import("infrastructure/media/ffmpeg.zig").FFmpeg;
const Downloader = @import("infrastructure/downloader/downloader.zig").Downloader;
const api = @import("helpers/api.zig");
const capabilities_model = @import("features/capabilities/model.zig");

/// Общие ресурсы и настройки HTTP-обработчиков и фоновых задач.
/// После первого обращения к S3 структура должна оставаться по стабильному адресу.
/// Строки настроек должны жить до остановки приложения.
pub const App = struct {
    /// Общий потокобезопасный аллокатор для рабочих арен; принадлежит среде запуска.
    allocator: std.mem.Allocator,
    /// Общая среда I/O для параллельных операций; живёт до остановки всех задач.
    io: std.Io,

    /// Пул БД; освобождается после остановки всех обработчиков и фоновых задач.
    db: Database,
    /// Общий S3-клиент с пулом HTTP-соединений.
    storage: S3,
    /// Общий клиент каталога; освобождается после остановки HTTP-сервера.
    catalog: Catalog,
    /// Анализатор аудио с настроенным путём к ffprobe.
    probe: Probe,
    /// Обработчик аудио и обложек с настроенным путём к FFmpeg.
    ffmpeg: FFmpeg,
    /// Общий загрузчик аудио из внешних источников.
    downloader: Downloader,

    /// Максимальный размер тела запроса и загружаемого файла в байтах.
    max_upload_bytes: usize,

    metadata_tmp_dir: []const u8,
    metadata_timeout_seconds: u32,

    imports_tmp_dir: []const u8,
    imports_timeout_seconds: u32,

    hls_tmp_dir: []const u8,
    hls_timeout_seconds: u32,

    cookie_secure: bool,
    registration_enabled: bool,

    /// Итоговые возможности после проверки зависимостей интеграций при запуске.
    capabilities: capabilities_model.Capabilities,

    /// Срок хранения общего трека без ссылок из пользовательских плейлистов.
    shared_track_retention_seconds: u32,

    /// Разрешает импорт, если доступна хотя бы одна интеграция: Web или Spotify.
    pub fn importsEnabled(self: *const App) bool {
        return self.capabilities.web_search or self.capabilities.spotify_import;
    }

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
