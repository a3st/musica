const Job = @import("../../infrastructure/jobs/model.zig").Job;
const tracks_model = @import("../tracks/model.zig");

/// Вид фоновой задачи скачивания трека через yt-dlp.
pub const download_job_kind = "download_track";

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

/// Название и исполнитель общего трека, полученные из внешнего каталога или импорта.
pub const Track = struct {
    title: []const u8,
    artist: []const u8,
};

/// Внешний источник для связи provider/external_id с внутренним track_id.
pub const Source = struct {
    /// Идентификатор источника: например, spotify или itunes.
    provider: []const u8,
    external_id: []const u8,
};

/// Проверяет метаданные общего трека и возвращает строки с обрезанными пробелами.
pub fn validateTrack(track: Track) !Track {
    const input = try tracks_model.validateCreate(.{ .title = track.title, .artist = track.artist });

    return .{
        .title = input.title,
        .artist = input.artist,
    };
}
