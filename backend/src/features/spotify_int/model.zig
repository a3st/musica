const std = @import("std");
const tracks_model = @import("../tracks/model.zig");
const playlists_model = @import("../playlists/model.zig");

/// Лимит общего числа записей треков в плейлистах и библиотеке до дедупликации.
pub const max_tracks = 5000;
/// Максимальное число плейлистов в одном импорте.
pub const max_playlists = 100;
/// Лимит JSON-тела запроса импорта в байтах.
pub const max_json_bytes = 4 * 1024 * 1024;

/// Метаданные трека из экспорта Spotify, подготовленные клиентом для API.
pub const Track = struct {
    title: []const u8,
    artist: []const u8,
    /// Необязательный URI вида spotify:track:<22 символа>, используемый для привязки источника.
    spotify_uri: ?[]const u8 = null,
};

/// Плейлист из экспорта Spotify с метаданными и списком треков.
pub const Playlist = struct {
    title: []const u8,
    description: []const u8 = "",
    tracks: []const Track,
};

/// Входные данные импорта; сырые Playlists.json и YourLibrary.json разбираются на клиенте.
pub const Import = struct {
    playlists: []const Playlist = &.{},
    library: []const Track = &.{},
};

/// Результат постановки загрузок в очередь; не означает завершение скачивания файлов.
pub const Result = struct {
    /// Число различных внутренних track_id, затронутых импортом.
    tracks: usize,
    /// ID созданных пользовательских плейлистов.
    playlists: []const []const u8,
};

/// Проверяет непустой импорт, суммарные лимиты и метаданные всех плейлистов и треков.
pub fn validateImport(input: Import) !void {
    if (input.playlists.len > max_playlists) return error.InvalidInput;

    var count = input.library.len;
    for (input.playlists) |playlist| {
        _ = try playlists_model.validateCreate(.{ .title = playlist.title, .description = playlist.description });
        count += playlist.tracks.len;
        if (count > max_tracks) return error.InvalidInput;
        for (playlist.tracks) |track| try validateTrack(track);
    }

    if (count == 0 or count > max_tracks) return error.InvalidInput;

    for (input.library) |track| try validateTrack(track);
}

/// Проверяет название, исполнителя и необязательный URI трека Spotify.
pub fn validateTrack(track: Track) !void {
    _ = try tracks_model.validateCreate(.{ .title = track.title, .artist = track.artist });

    if (track.spotify_uri) |uri| {
        const prefix = "spotify:track:";
        if (!std.mem.startsWith(u8, uri, prefix) or uri.len != prefix.len + 22) return error.InvalidInput;
        for (uri[prefix.len..]) |c| if (!std.ascii.isAlphanumeric(c)) return error.InvalidInput;
    }
}

/// Возвращает ключ дедупликации внутри одного импорта: Spotify URI или исполнитель и название.
/// URI ссылается на входные данные; ключ по метаданным с обрезанными пробелами и ASCII-регистром выделяется в arena.
pub fn importDeduplicationKey(arena: std.mem.Allocator, track: Track) ![]const u8 {
    if (track.spotify_uri) |uri| return uri;

    return std.fmt.allocPrint(arena, "{s}\x00{s}", .{
        try std.ascii.allocLowerString(arena, std.mem.trim(u8, track.artist, " \t\r\n")),
        try std.ascii.allocLowerString(arena, std.mem.trim(u8, track.title, " \t\r\n")),
    });
}

test "Spotify metadata rejects URLs, oversized imports and empty track names" {
    try std.testing.expectError(error.InvalidInput, validateImport(.{}));
    const too_many = [_]Track{.{ .title = "Track", .artist = "Artist" }} ** (max_tracks + 1);

    try std.testing.expectError(error.InvalidInput, validateImport(.{ .library = &too_many }));
    try std.testing.expectError(error.InvalidText, validateTrack(.{ .title = " ", .artist = "Artist" }));
    try std.testing.expectError(error.InvalidInput, validateTrack(.{ .title = "Title", .artist = "Artist", .spotify_uri = "https://example.org" }));
    try validateTrack(.{ .title = "Get Lucky", .artist = "Daft Punk", .spotify_uri = "spotify:track:0123456789012345678901" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings(
        try importDeduplicationKey(arena.allocator(), .{ .title = " Title ", .artist = "ARTIST" }),
        try importDeduplicationKey(arena.allocator(), .{ .title = "title", .artist = "artist" }),
    );
}
