const std = @import("std");
const model = @import("model.zig");
const YtDlp = @import("providers/yt_dlp.zig").YtDlp;

/// Настройки инструментов и последовательности fallback; строки и список заимствуются.
pub const Settings = struct {
    ytdlp_path: []const u8,
    ffmpeg_path: []const u8,

    /// Провайдеры вызываются по порядку; пустой список запрещает скачивание.
    providers: []const model.Provider = &.{.yt_dlp},
};

/// Общая точка скачивания аудио; выбор инструмента скрыт от worker импорта.
pub const Downloader = struct {
    /// Заимствованный список; должен жить дольше экземпляра Downloader.
    providers: []const model.Provider,
    yt_dlp: YtDlp,

    /// Создаёт провайдеры без выделения ресурсов; пути и список должны жить дольше экземпляра.
    pub fn init(settings: Settings) Downloader {
        return .{
            .providers = settings.providers,
            .yt_dlp = YtDlp.init(settings.ytdlp_path, settings.ffmpeg_path),
        };
    }

    /// Последовательно пробует провайдеры в отдельных подпапках dir; путь результата выделяется в arena.
    /// Только ошибки источника разрешают fallback; отмена, лимиты и локальные ошибки завершают вызов.
    /// Таймаут, аренда задачи и удаление файлов задаются вызывающим кодом; max_bytes задаёт лимит файла.
    pub fn download(
        self: *const Downloader,
        arena: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        request: model.Request,
        max_bytes: usize,
    ) !model.Result {
        for (self.providers, 0..) |provider, index| {
            const sub_path = try std.fmt.allocPrint(arena, "{d}-{s}", .{ index, @tagName(provider) });
            var provider_dir = try dir.createDirPathOpen(io, sub_path, .{});
            defer provider_dir.close(io);

            const result = self.downloadWithProvider(
                provider,
                arena,
                io,
                provider_dir,
                request,
                max_bytes,
            ) catch |err| {
                if (!allowsFallback(err)) return err;

                std.log.warn("Download provider {s} failed: {s}", .{ @tagName(provider), @errorName(err) });
                continue;
            };

            return .{
                .audio_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ sub_path, result.audio_path }),
                .content_type = result.content_type,
            };
        }

        return error.DownloadFailed;
    }

    /// Вызывает инструмент и проверяет наличие и размер результата до выбора следующего провайдера.
    fn downloadWithProvider(
        self: *const Downloader,
        provider: model.Provider,
        arena: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        request: model.Request,
        max_bytes: usize,
    ) !model.Result {
        const result = switch (provider) {
            .yt_dlp => try self.yt_dlp.download(arena, io, dir, request, max_bytes),
        };

        const stat = dir.statFile(io, result.audio_path, .{}) catch |err| {
            if (err == error.FileNotFound) return error.DownloadFailed;

            return err;
        };
        if (stat.size == 0) return error.EmptyFile;
        if (stat.size > max_bytes) return error.FileTooLarge;

        return result;
    }
};

/// Разрешает смену источника, но не скрывает отмену, ошибки среды или ограничения приложения.
fn allowsFallback(err: anyerror) bool {
    return switch (err) {
        error.DownloadFailed, error.TrackNotFound, error.SourceUnavailable => true,
        else => false,
    };
}

test "provider fallback preserves cancellation, file limits and local failures" {
    try std.testing.expect(allowsFallback(error.DownloadFailed));
    try std.testing.expect(allowsFallback(error.TrackNotFound));
    try std.testing.expect(allowsFallback(error.SourceUnavailable));

    try std.testing.expect(!allowsFallback(error.Canceled));
    try std.testing.expect(!allowsFallback(error.FileTooLarge));
    try std.testing.expect(!allowsFallback(error.EmptyFile));
    try std.testing.expect(!allowsFallback(error.FileNotFound));
    try std.testing.expect(!allowsFallback(error.AccessDenied));
    try std.testing.expect(!allowsFallback(error.OutOfMemory));
}

test "empty provider list rejects downloads without accessing IO" {
    const downloader = Downloader.init(.{
        .ytdlp_path = "yt-dlp",
        .ffmpeg_path = "ffmpeg",
        .providers = &.{},
    });

    try std.testing.expectError(error.DownloadFailed, downloader.download(
        std.testing.allocator,
        undefined,
        undefined,
        .{ .title = "Song", .artist = "Artist" },
        1024,
    ));
}
