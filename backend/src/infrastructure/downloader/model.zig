/// Инструменты скачивания; порядок их использования задаётся настройками Downloader.
pub const Provider = enum {
    yt_dlp,
};

/// Данные для поиска аудио; не содержат настройки загрузки, ID трека или задачи.
pub const Request = struct {
    title: []const u8,
    artist: []const u8,
};

/// Локальный результат скачивания; путь разрешается относительно каталога вызова.
/// Владение временными файлами и их удаление остаются у вызывающего кода.
pub const Result = struct {
    audio_path: []const u8,
    content_type: []const u8,
};
