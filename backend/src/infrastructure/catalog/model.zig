const std = @import("std");

/// Провайдеры, поддерживаемые поисковым каталогом.
pub const Provider = enum {
    itunes,
};

/// Поисковый источник с готовым ключом кеша; ключ живёт до освобождения arena.
pub const SearchSource = struct {
    provider: Provider,
    cache_key: []const u8,
};

/// Метаданные песни от HTTP-клиента без идентификатора поискового провайдера.
pub const Track = struct {
    external_id: []const u8,
    title: []const u8,
    artist: []const u8,
    album: ?[]const u8 = null,
    artwork_url: ?[]const u8 = null,
    source_url: ?[]const u8 = null,
};

/// Метаданные внешней песни с источником, назначенным каталогом.
pub const SearchTrack = struct {
    provider: Provider,
    external_id: []const u8,
    title: []const u8,
    artist: []const u8,
    album: ?[]const u8 = null,
    artwork_url: ?[]const u8 = null,
    source_url: ?[]const u8 = null,
};

/// Принимает положительный числовой ID iTunes без URL и произвольных параметров.
pub fn validateExternalId(id: []const u8) !void {
    if (id.len == 0 or id.len > 20) return error.InvalidInput;

    for (id) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidInput;

    if ((std.fmt.parseInt(u64, id, 10) catch return error.InvalidInput) == 0)
        return error.InvalidInput;
}
