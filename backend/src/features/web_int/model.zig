const std = @import("std");
const catalog_model = @import("../../infrastructure/catalog/model.zig");
const tracks_model = @import("../tracks/model.zig");
const jobs_model = @import("../../infrastructure/jobs/model.zig");

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

/// Проверяет непустой поисковый запрос от 2 до 256 байт в UTF-8.
pub fn validateSearch(query: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len < 2 or trimmed.len > 256 or !std.unicode.utf8ValidateSlice(trimmed))
        return error.InvalidInput;
    return trimmed;
}

pub const validateExternalId = catalog_model.validateExternalId;

test "Catalog selection requires a supported provider and an external ID" {
    const valid = try std.json.parseFromSlice(Selection, std.testing.allocator,
        \\{"provider":"itunes","external_id":"123"}
    , .{});
    defer valid.deinit();

    try std.testing.expectEqual(Provider.itunes, valid.value.provider);
    try validateExternalId(valid.value.external_id);

    const deezer = try std.json.parseFromSlice(Selection, std.testing.allocator,
        \\{"provider":"deezer","external_id":"2645471652"}
    , .{});
    defer deezer.deinit();

    try std.testing.expectEqual(Provider.deezer, deezer.value.provider);
    try validateExternalId(deezer.value.external_id);

    try std.testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(Selection, std.testing.allocator,
        \\{"provider":"unknown","external_id":"123"}
    , .{}));
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(Selection, std.testing.allocator,
        \\{"external_id":"123"}
    , .{}));
}
