const std = @import("std");
const Job = @import("../../infrastructure/jobs/model.zig").Job;
const catalog_model = @import("../../infrastructure/catalog/model.zig");
const tracks_model = @import("../tracks/model.zig");
const jobs_model = @import("../../infrastructure/jobs/model.zig");

/// Вид фоновой задачи скачивания трека через yt-dlp.
pub const download_job_kind = "download_track";

/// Вид задачи удаления общего трека, утратившего пользовательские привязки.
pub const cleanup_job_kind = "delete_unused_track";

pub const Provider = catalog_model.Provider;

pub const SearchTrack = catalog_model.SearchTrack;

pub const Track = tracks_model.Track;

/// Загруженные сервисные треки и дополнительные результаты каталога без повторов.
pub const SearchResult = struct {
    library: []const Track,
    catalog: []const SearchTrack,
};

/// Выбранный результат; название и исполнитель проверяются через каталог на сервере.
pub const Selection = struct {
    provider: Provider,
    external_id: []const u8,
    add_to_library: bool = true,
};

/// Состояние скачивания и данные для запуска плеера.
pub const Playback = struct {
    track: Track,
    download: ?jobs_model.State,
};

/// Данные задачи скачивания существующего трека в сервисную учётку.
pub const Payload = struct {
    /// ID сервисной учётки, владеющей треком.
    user_id: []const u8,
    track_id: []const u8,
    track: CatalogTrack,
};

/// Арендованная задача скачивания с разобранным payload.
pub const Task = struct {
    job: Job,
    payload: Payload,
};

/// Название и исполнитель общего трека, полученные из внешнего каталога или импорта.
pub const CatalogTrack = struct {
    title: []const u8,
    artist: []const u8,
};

/// Внешний источник для связи provider/external_id с внутренним track_id.
pub const Source = struct {
    /// Идентификатор источника: например, spotify или itunes.
    provider: []const u8,
    external_id: []const u8,
};

/// Проверяет непустой поисковый запрос от 2 до 256 байт в UTF-8.
pub fn validateSearch(query: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len < 2 or trimmed.len > 256 or !std.unicode.utf8ValidateSlice(trimmed))
        return error.InvalidInput;
    return trimmed;
}

pub const validateExternalId = catalog_model.validateExternalId;

/// Проверяет метаданные общего трека и возвращает строки с обрезанными пробелами.
pub fn validateTrack(track: CatalogTrack) !CatalogTrack {
    const input = try tracks_model.validateCreate(.{ .title = track.title, .artist = track.artist });

    return .{
        .title = input.title,
        .artist = input.artist,
    };
}

test "Catalog selection requires a supported provider and an external ID" {
    const valid = try std.json.parseFromSlice(Selection, std.testing.allocator,
        \\{"provider":"itunes","external_id":"123"}
    , .{});
    defer valid.deinit();

    try std.testing.expectEqual(Provider.itunes, valid.value.provider);
    try validateExternalId(valid.value.external_id);

    try std.testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(Selection, std.testing.allocator,
        \\{"provider":"deezer","external_id":"123"}
    , .{}));
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(Selection, std.testing.allocator,
        \\{"external_id":"123"}
    , .{}));
}
