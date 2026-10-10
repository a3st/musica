const Job = @import("../../infrastructure/jobs/model.zig").Job;

/// Вид фоновой задачи скачивания трека через yt-dlp.
pub const download_job_kind = "download_track";

/// Вид задачи удаления общего трека, утратившего пользовательские привязки.
pub const cleanup_job_kind = "delete_unused_track";

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
