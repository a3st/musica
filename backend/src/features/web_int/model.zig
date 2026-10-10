const std = @import("std");
const Job = @import("../../infrastructure/jobs/model.zig").Job;

/// Вид фоновой задачи скачивания трека через yt-dlp.
pub const download_job_kind = "download_track";

/// Вид задачи удаления общего трека, утратившего пользовательские привязки.
pub const cleanup_job_kind = "delete_unused_track";

/// Метаданные результата iTunes; длительность в секундах, ID принадлежит провайдеру.
pub const SearchTrack = struct {
    external_id: []const u8,
    title: []const u8,
    artist: []const u8,
    album: ?[]const u8 = null,
    duration_seconds: ?u32 = null,
    artwork_url: ?[]const u8 = null,
    store_url: ?[]const u8 = null,
};

/// Выбранный результат; название и исполнитель проверяются через каталог на сервере.
pub const Selection = struct {
    external_id: []const u8,
};

/// Метаданные общего трека для поиска и скачивания.
pub const Track = struct {
    title: []const u8,
    artist: []const u8,
};

/// Данные задачи скачивания существующего трека в сервисную учётку.
pub const Payload = struct {
    /// ID сервисной учётки, владеющей треком.
    user_id: []const u8,
    track_id: []const u8,
    track: Track,
};

/// Арендованная задача скачивания с разобранным payload.
pub const Task = struct {
    job: Job,
    payload: Payload,
};

/// Внешний источник для связи provider/external_id с внутренним track_id.
pub const Source = struct {
    /// Идентификатор провайдера: spotify или itunes.
    provider: []const u8,
    external_id: []const u8,
};

/// Ограничивает длину запроса и исключает пустые строки.
pub fn validateSearch(term: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, term, " \t\r\n");
    if (trimmed.len < 2 or trimmed.len > 256 or !std.unicode.utf8ValidateSlice(trimmed))
        return error.InvalidInput;
    return trimmed;
}

/// Принимает положительный числовой ID iTunes без URL и произвольных параметров.
pub fn validateExternalId(id: []const u8) !void {
    if (id.len == 0 or id.len > 20) return error.InvalidInput;
    for (id) |c| if (!std.ascii.isDigit(c)) return error.InvalidInput;
    if ((std.fmt.parseInt(u64, id, 10) catch return error.InvalidInput) == 0)
        return error.InvalidInput;
}
