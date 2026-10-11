const std = @import("std");
const catalog_model = @import("../model.zig");
const retry = @import("../../../helpers/retry.zig");

/// Общий HTTP-клиент каталога; после первого запроса не копируйте экземпляр.
pub const DeezerClient = struct {
    client: std.http.Client,
    limit: u32,

    /// Создаёт клиент с лимитом результатов каждого поискового запроса.
    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        limit: u32,
    ) DeezerClient {
        return .{
            .client = .{
                .io = io,
                .allocator = allocator,
            },
            .limit = limit,
        };
    }

    /// Закрывает соединения каталога и освобождает ресурсы клиента.
    pub fn deinit(self: *DeezerClient) void {
        self.client.deinit();
        self.* = undefined;
    }

    /// Ищет песни с заданным лимитом; исполнителя берёт из artist, без запроса contributors.
    pub fn search(
        self: *DeezerClient,
        arena: std.mem.Allocator,
        query: []const u8,
    ) ![]const catalog_model.Track {
        const encoded = try encodeQuery(arena, query);
        const url = try std.fmt.allocPrint(
            arena,
            "https://api.deezer.com/search?q={s}&limit={d}",
            .{ encoded, self.limit },
        );

        return parseTracks(arena, try self.fetch(arena, url));
    }

    /// Читает подтверждённые метаданные выбранного ID; отсутствие песни — NotFound.
    pub fn lookup(
        self: *DeezerClient,
        arena: std.mem.Allocator,
        id: []const u8,
    ) !catalog_model.Track {
        try catalog_model.validateExternalId(id);

        const url = try std.fmt.allocPrint(arena, "https://api.deezer.com/track/{s}", .{id});
        const track = try parseTrack(arena, try self.fetch(arena, url));
        const numeric_id = try std.fmt.parseInt(u64, id, 10);
        if (try std.fmt.parseInt(u64, track.external_id, 10) != numeric_id) return error.NotFound;

        return track;
    }

    /// Ограничивает тело двумя МиБ, время запроса — 20 секундами; подробности ошибок остаются в логах.
    fn fetch(self: *DeezerClient, arena: std.mem.Allocator, url: []const u8) ![]const u8 {
        var writer: std.Io.Writer = .fixed(try arena.alloc(u8, 2 * 1024 * 1024));
        const Result = union(enum) {
            response: anyerror!void,
            deadline: anyerror!void,
        };

        var buffer: [2]Result = undefined;
        var select = std.Io.Select(Result).init(self.client.io, &buffer);
        defer select.cancelDiscard();

        try select.concurrent(.response, fetchWithRetry, .{ self, url, &writer });
        try select.concurrent(.deadline, deadline, .{self.client.io});

        switch (try select.await()) {
            .response => |result| result catch |err| {
                std.log.err("Deezer request failed: {s}", .{@errorName(err)});
                return error.CatalogUnavailable;
            },
            .deadline => return error.CatalogUnavailable,
        }

        return writer.buffered();
    }

    /// Контекст GET; ответ каждой попытки начинается с пустого буфера.
    const FetchContext = struct {
        deezer: *DeezerClient,
        url: []const u8,
        writer: *std.Io.Writer,

        /// Сбрасывает частичный ответ, сохраняя выделенную память.
        fn beforeAttempt(self: *FetchContext, _: u8) !void {
            self.writer.end = 0;
        }

        /// Выполняет одну попытку GET с включённым keep-alive.
        fn perform(self: *FetchContext) !void {
            try self.deezer.fetchOnce(self.url, self.writer);
        }
    };

    /// Выполняет до трёх GET-попыток при временных сетевых ошибках в пределах общего таймаута.
    fn fetchWithRetry(self: *DeezerClient, url: []const u8, writer: *std.Io.Writer) !void {
        var context: FetchContext = .{
            .deezer = self,
            .url = url,
            .writer = writer,
        };

        try retry.run(self.client.io, .{}, &context, FetchContext.beforeAttempt, FetchContext.perform, shouldRetry);
    }

    /// Выполняет GET по фиксированному адресу провайдера; адрес клиента не принимается извне.
    fn fetchOnce(self: *DeezerClient, url: []const u8, writer: *std.Io.Writer) !void {
        const response = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = writer,
            .keep_alive = true,
        });

        if (response.status != .ok) {
            std.log.warn("Deezer returned HTTP {d}", .{@intFromEnum(response.status)});
            return error.CatalogUnavailable;
        }
    }
};

/// Повторяет только сетевые сбои; отмена, HTTP-ошибки и переполнение буфера завершают вызов.
fn shouldRetry(err: anyerror) bool {
    return switch (err) {
        error.HttpConnectionClosing,
        error.HttpRequestTruncated,
        error.HttpChunkTruncated,
        error.ConnectionResetByPeer,
        error.ConnectionRefused,
        error.ConnectionTimedOut,
        error.Timeout,
        error.BrokenPipe,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.ReadFailed,
        => true,
        else => false,
    };
}

/// Завершает ожидание внешнего каталога через двадцать секунд.
fn deadline(io: std.Io) !void {
    try std.Io.sleep(io, .fromSeconds(20), .awake);
}

/// Кодирует UTF-8 байты запроса без возможности внедрить дополнительные URL-параметры.
fn encodeQuery(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    const output = try arena.alloc(u8, value.len * 3);
    const hex = "0123456789ABCDEF";
    var length: usize = 0;

    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            output[length] = byte;
            length += 1;
        } else {
            output[length..][0..3].* = .{ '%', hex[byte >> 4], hex[byte & 15] };
            length += 3;
        }
    }

    return output[0..length];
}

/// Внешние метаданные Deezer; contributors и длительность намеренно не запрашиваются.
const Song = struct {
    id: ?u64 = null,
    type: ?[]const u8 = null,
    title: ?[]const u8 = null,
    artist: ?struct { name: ?[]const u8 = null } = null,
    album: ?struct {
        title: ?[]const u8 = null,
        cover_medium: ?[]const u8 = null,
    } = null,
    link: ?[]const u8 = null,
};

/// Разбирает поисковую выдачу; ошибки API даже с HTTP 200 не кешируются как пустой результат.
fn parseTracks(arena: std.mem.Allocator, body: []const u8) ![]const catalog_model.Track {
    const parsed = std.json.parseFromSlice(struct {
        data: ?[]const Song = null,
        @"error": ?struct { code: i64 = 0 } = null,
    }, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.CatalogUnavailable;

    if (parsed.value.@"error" != null) return error.CatalogUnavailable;
    const songs = parsed.value.data orelse return error.CatalogUnavailable;
    var tracks: std.ArrayList(catalog_model.Track) = .empty;

    for (songs) |song| {
        const track = try mapSong(arena, song) orelse continue;
        try tracks.append(arena, track);
    }

    return tracks.toOwnedSlice(arena);
}

/// Подтверждает выбранную песню; код Deezer 800 означает отсутствие записи.
fn parseTrack(arena: std.mem.Allocator, body: []const u8) !catalog_model.Track {
    const api_response = std.json.parseFromSlice(struct {
        @"error": ?struct { code: i64 = 0 } = null,
    }, arena, body, .{ .ignore_unknown_fields = true }) catch return error.CatalogUnavailable;
    defer api_response.deinit();

    if (api_response.value.@"error") |failure| {
        return if (failure.code == 800) error.NotFound else error.CatalogUnavailable;
    }

    const parsed = std.json.parseFromSlice(Song, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.CatalogUnavailable;

    return (try mapSong(arena, parsed.value)) orelse return error.NotFound;
}

/// Сохраняет полное название версии и основного исполнителя; строки принадлежат arena.
fn mapSong(arena: std.mem.Allocator, song: Song) !?catalog_model.Track {
    if (!std.mem.eql(u8, song.type orelse "", "track")) return null;

    const id = song.id orelse return null;
    const title = song.title orelse return null;
    const artist = (song.artist orelse return null).name orelse return null;
    if (id == 0 or title.len == 0 or artist.len == 0 or title.len > 256 or artist.len > 256) return null;

    return .{
        .external_id = try std.fmt.allocPrint(arena, "{d}", .{id}),
        .title = title,
        .artist = artist,
        .album = if (song.album) |album| album.title else null,
        .artwork_url = if (song.album) |album| secureUrl(album.cover_medium) else null,
        .source_url = secureUrl(song.link),
    };
}

/// Пропускает только HTTPS-ссылки из метаданных провайдера.
fn secureUrl(value: ?[]const u8) ?[]const u8 {
    const url = value orelse return null;

    return if (std.mem.startsWith(u8, url, "https://")) url else null;
}

test "Deezer preserves versions and the primary artist without contributors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tracks = try parseTracks(arena.allocator(),
        \\{"data":[{"id":1,"type":"album","title":"Album"},
        \\{"id":2,"type":"track","title":"Song (Live Remix)","artist":{"name":"Primary"},
        \\"contributors":[{"name":"Guest"}],"explicit_lyrics":true,
        \\"album":{"title":"Album","cover_medium":"https://example.com/cover.jpg"},"link":"https://www.deezer.com/track/2"},
        \\{"id":3,"type":"track","title":"Song","artist":{"name":"Artist"},"link":"javascript:bad"}]}
    );

    try std.testing.expectEqual(@as(usize, 2), tracks.len);
    try std.testing.expectEqualStrings("Song (Live Remix)", tracks[0].title);
    try std.testing.expectEqualStrings("Primary", tracks[0].artist);
    try std.testing.expectEqualStrings("https://example.com/cover.jpg", tracks[0].artwork_url.?);
    try std.testing.expect(tracks[1].source_url == null);
}

test "Deezer distinguishes empty searches from API errors and missing songs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqual(@as(usize, 0), (try parseTracks(allocator, "{\"data\":[]}")).len);
    try std.testing.expectError(error.CatalogUnavailable, parseTracks(allocator, "{\"error\":{\"code\":4}}"));
    try std.testing.expectError(error.NotFound, parseTrack(allocator, "{\"error\":{\"code\":800}}"));
    try std.testing.expectError(error.CatalogUnavailable, parseTrack(allocator, "{\"error\":{\"code\":4}}"));
    const song = try parseTrack(allocator, "{\"id\":2,\"type\":\"track\",\"title\":\"Song\",\"artist\":{\"name\":\"Artist\"}}");
    try std.testing.expectEqualStrings("2", song.external_id);
    try std.testing.expectEqualStrings("Live%20%26%20Remix%2F%3F", try encodeQuery(allocator, "Live & Remix/?"));
}
