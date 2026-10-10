const std = @import("std");
const ITunesClient = @import("providers/itunes.zig").ITunesClient;
const model = @import("model.zig");

/// Единая точка доступа к внешним каталогам; пока подключён только iTunes.
pub const Catalog = struct {
    itunes: ITunesClient,

    /// Создаёт клиенты провайдеров; после первого запроса экземпляр нельзя копировать.
    pub fn init(io: std.Io, allocator: std.mem.Allocator) Catalog {
        return .{ .itunes = ITunesClient.init(io, allocator, "US", 25) };
    }

    /// Освобождает HTTP-клиенты после остановки сервера и фоновых задач.
    pub fn deinit(self: *Catalog) void {
        self.itunes.deinit();
        self.* = undefined;
    }

    /// Возвращает подключённые источники с ключами для запроса; память принадлежит arena.
    pub fn searchSources(
        self: *const Catalog,
        arena: std.mem.Allocator,
        query: []const u8,
    ) ![]const model.SearchSource {
        const sources = try arena.alloc(model.SearchSource, 1);
        sources[0] = .{
            .provider = .itunes,
            .cache_key = try self.searchCacheKey(arena, .itunes, query),
        };

        return sources;
    }

    /// Возвращает результаты одного провайдера; сервис объединяет их после чтения отдельных кешей.
    pub fn search(
        self: *Catalog,
        arena: std.mem.Allocator,
        provider: model.Provider,
        query: []const u8,
    ) ![]const model.SearchTrack {
        const tracks = try switch (provider) {
            .itunes => self.itunes.search(arena, query),
        };

        const results = try arena.alloc(model.SearchTrack, tracks.len);
        for (tracks, results) |track, *result| {
            result.* = identifyTrack(provider, track);
        }

        return results;
    }

    /// Формирует ключ кеша с версией формата и параметрами подключённого провайдера; память принадлежит arena.
    fn searchCacheKey(
        self: *const Catalog,
        arena: std.mem.Allocator,
        provider: model.Provider,
        query: []const u8,
    ) ![]const u8 {
        return switch (provider) {
            .itunes => std.fmt.allocPrint(
                arena,
                "catalog:v2:search:{s}:{s}:{d}:{s}",
                .{ @tagName(provider), self.itunes.country, self.itunes.limit, query },
            ),
        };
    }

    /// Формирует ключ подтверждённых метаданных с параметрами выбранного провайдера.
    pub fn lookupCacheKey(
        self: *const Catalog,
        arena: std.mem.Allocator,
        provider: model.Provider,
        external_id: []const u8,
    ) ![]const u8 {
        return switch (provider) {
            .itunes => std.fmt.allocPrint(
                arena,
                "catalog:v2:lookup:{s}:{s}:{s}",
                .{ @tagName(provider), self.itunes.country, external_id },
            ),
        };
    }

    /// Подтверждает метаданные выбранной песни у указанного провайдера.
    pub fn lookup(
        self: *Catalog,
        arena: std.mem.Allocator,
        provider: model.Provider,
        external_id: []const u8,
    ) !model.SearchTrack {
        const track = try switch (provider) {
            .itunes => self.itunes.lookup(arena, external_id),
        };

        return identifyTrack(provider, track);
    }
};

/// Добавляет источник к метаданным клиента; строки сохраняют время жизни исходного аллокатора.
fn identifyTrack(provider: model.Provider, track: model.Track) model.SearchTrack {
    return .{
        .provider = provider,
        .external_id = track.external_id,
        .title = track.title,
        .artist = track.artist,
        .album = track.album,
        .artwork_url = track.artwork_url,
        .source_url = track.source_url,
    };
}

test "Catalog attaches the selected provider without losing recording metadata" {
    const track: model.Track = .{
        .external_id = "123",
        .title = "Song (Live Remix)",
        .artist = "Artist",
        .album = "Album",
        .artwork_url = "https://example.com/artwork.jpg",
        .source_url = "https://example.com/song/123",
    };
    const result = identifyTrack(.itunes, track);

    try std.testing.expectEqual(model.Provider.itunes, result.provider);
    try std.testing.expectEqualStrings(track.external_id, result.external_id);
    try std.testing.expectEqualStrings(track.title, result.title);
    try std.testing.expectEqualStrings(track.artist, result.artist);
    try std.testing.expectEqualStrings(track.album.?, result.album.?);
    try std.testing.expectEqualStrings(track.artwork_url.?, result.artwork_url.?);
    try std.testing.expectEqualStrings(track.source_url.?, result.source_url.?);

    const without_images = identifyTrack(.itunes, .{
        .external_id = "124",
        .title = "Song",
        .artist = "Artist",
    });
    try std.testing.expect(without_images.album == null);
    try std.testing.expect(without_images.artwork_url == null);
    try std.testing.expect(without_images.source_url == null);
}
