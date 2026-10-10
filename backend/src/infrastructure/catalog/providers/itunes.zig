const std = @import("std");
const catalog_model = @import("../model.zig");

/// Общий HTTP-клиент каталога; после первого запроса не копируйте экземпляр.
pub const ITunesClient = struct {
    client: std.http.Client,
    country: []const u8,
    limit: u32,

    /// Создаёт клиент с параметрами поиска; country должен жить до deinit.
    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        country: []const u8,
        limit: u32,
    ) ITunesClient {
        return .{
            .client = .{
                .io = io,
                .allocator = allocator,
            },
            .country = country,
            .limit = limit,
        };
    }

    /// Закрывает соединения каталога и освобождает ресурсы клиента.
    pub fn deinit(self: *ITunesClient) void {
        self.client.deinit();
        self.* = undefined;
    }

    /// Ищет песни с заданными страной и лимитом; запрос кодируется как URL-компонент.
    pub fn search(
        self: *ITunesClient,
        arena: std.mem.Allocator,
        query: []const u8,
    ) ![]const catalog_model.Track {
        const encoded = try encodeQuery(arena, query);
        const url = try std.fmt.allocPrint(
            arena,
            "https://itunes.apple.com/search?term={s}&country={s}&media=music&entity=song&limit={d}",
            .{ encoded, self.country, self.limit },
        );

        return parseTracks(arena, try self.fetch(arena, url));
    }

    /// Читает подтверждённые метаданные выбранного ID; отсутствие песни — NotFound.
    pub fn lookup(
        self: *ITunesClient,
        arena: std.mem.Allocator,
        id: []const u8,
    ) !catalog_model.Track {
        try catalog_model.validateExternalId(id);

        const url = try std.fmt.allocPrint(
            arena,
            "https://itunes.apple.com/lookup?id={s}&country={s}&entity=song",
            .{ id, self.country },
        );
        const tracks = try parseTracks(arena, try self.fetch(arena, url));
        const numeric_id = try std.fmt.parseInt(u64, id, 10);

        for (tracks) |track| {
            if (try std.fmt.parseInt(u64, track.external_id, 10) == numeric_id) return track;
        }

        return error.NotFound;
    }

    /// Ограничивает тело двумя МиБ, время запроса — 20 секундами; подробности ошибок остаются в логах.
    fn fetch(self: *ITunesClient, arena: std.mem.Allocator, url: []const u8) ![]const u8 {
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
                std.log.err("iTunes request failed: {s}", .{@errorName(err)});
                return error.CatalogUnavailable;
            },
            .deadline => return error.CatalogUnavailable,
        }

        return writer.buffered();
    }

    /// Повторяет GET один раз, если соединение из пула закрылось до получения ответа.
    fn fetchWithRetry(self: *ITunesClient, url: []const u8, writer: *std.Io.Writer) !void {
        self.fetchOnce(url, writer) catch |err| {
            if (err != error.HttpConnectionClosing) return err;

            try self.fetchOnce(url, writer);
        };
    }

    /// Выполняет GET по фиксированному адресу провайдера; адрес клиента не принимается извне.
    fn fetchOnce(self: *ITunesClient, url: []const u8, writer: *std.Io.Writer) !void {
        const response = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = writer,
            .keep_alive = true,
        });

        if (response.status != .ok) {
            std.log.warn("iTunes returned HTTP {d}", .{@intFromEnum(response.status)});
            return error.CatalogUnavailable;
        }
    }
};

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

/// Разбирает ответ провайдера и исключает записи, не являющиеся песнями.
fn parseTracks(arena: std.mem.Allocator, body: []const u8) ![]const catalog_model.Track {
    const Song = struct {
        kind: ?[]const u8 = null,
        trackId: ?u64 = null,
        trackName: ?[]const u8 = null,
        artistName: ?[]const u8 = null,
        collectionName: ?[]const u8 = null,
        artworkUrl100: ?[]const u8 = null,
        trackViewUrl: ?[]const u8 = null,
    };

    const parsed = std.json.parseFromSlice(struct { results: []const Song }, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.CatalogUnavailable;

    var tracks: std.ArrayList(catalog_model.Track) = .empty;

    for (parsed.value.results) |song| {
        if (!std.mem.eql(u8, song.kind orelse "", "song")) continue;

        const id = song.trackId orelse continue;
        const title = song.trackName orelse continue;
        const artist = song.artistName orelse continue;
        if (id == 0 or title.len == 0 or artist.len == 0 or title.len > 256 or artist.len > 256) continue;

        try tracks.append(arena, .{
            .external_id = try std.fmt.allocPrint(arena, "{d}", .{id}),
            .title = title,
            .artist = artist,
            .album = song.collectionName,
            .artwork_url = secureUrl(song.artworkUrl100),
            .source_url = secureUrl(song.trackViewUrl),
        });
    }

    return tracks.toOwnedSlice(arena);
}

/// Пропускает только HTTPS-ссылки из метаданных провайдера.
fn secureUrl(value: ?[]const u8) ?[]const u8 {
    const url = value orelse return null;

    return if (std.mem.startsWith(u8, url, "https://")) url else null;
}

test "iTunes query encoding isolates URL parameters and Unicode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings("Live%20%26%20Remix%2F%3F", try encodeQuery(arena.allocator(), "Live & Remix/?"));
}

test "iTunes results preserve recording names and reject non-song entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tracks = try parseTracks(arena.allocator(),
        \\{"results":[{"kind":"music-video","trackId":1},
        \\{"kind":"song","trackId":2,"trackName":"Song (Live Remix)","artistName":"Artist","trackTimeMillis":123456,"artworkUrl100":"javascript:bad"}]}
    );

    try std.testing.expectEqual(@as(usize, 1), tracks.len);
    try std.testing.expectEqualStrings("Song (Live Remix)", tracks[0].title);
    try std.testing.expect(tracks[0].artwork_url == null);
}
