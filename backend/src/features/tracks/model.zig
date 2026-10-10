const std = @import("std");
const Job = @import("../../infrastructure/jobs/model.zig").Job;

/// Вид задачи, используемой для аренды загрузки исходного файла.
pub const upload_job_kind = "upload_track";

/// Вид задачи удаления объектов из S3.
pub const cleanup_job_kind = "delete_s3_objects";

/// Вид задачи чтения длительности и извлечения встроенной обложки.
pub const metadata_job_kind = "inspect_track";

/// Максимальный размер нормализованной JPEG-обложки.
pub const max_artwork_bytes = 2 * 1024 * 1024;

/// Исходник для обработки; адрес фиксируется при публикации загрузки.
pub const MetadataPayload = struct {
    track_id: []const u8,
    bucket: []const u8,
    key: []const u8,
    size: usize,
};

/// Арендованная задача извлечения метаданных трека.
pub const MetadataTask = struct {
    job: Job,
    payload: MetadataPayload,
};

/// Длительность реального файла и ключ отдельно опубликованной обложки.
pub const Metadata = struct {
    duration_seconds: ?u32,
    artwork_key: ?[]const u8,
};

/// Адрес исходного файла трека в S3; key — ключ объекта внутри бакета.
pub const UploadLocation = struct {
    bucket: []const u8,
    key: []const u8,
};

/// Состояние готовности исходного файла и HLS-представления трека.
pub const Status = enum {
    /// Метаданные созданы, исходный файл ещё не опубликован.
    pending,
    /// Исходный файл загружен, HLS ещё не опубликован.
    ready,
    /// HLS-манифест и сегменты опубликованы и доступны для воспроизведения.
    streamed,
};

/// Данные аренды загрузки исходного файла.
pub const UploadPayload = struct {
    track_id: []const u8,
    bucket: []const u8,
    key: []const u8,
};

/// Объекты для удаления в одном бакете; keys содержит ключи, а не URL.
pub const CleanupPayload = struct {
    bucket: []const u8,
    keys: []const []const u8,
};

/// Арендованная задача очистки с разобранными данными удаления.
pub const CleanupTask = struct {
    job: Job,
    payload: CleanupPayload,
};

/// Адреса файлов трека для удаления исходника и опубликованного HLS.
pub const Files = struct {
    bucket: []const u8,
    key: []const u8,
    artwork_key: ?[]const u8,

    /// Префикс опубликованного HLS; null, если HLS отсутствует.
    prefix: ?[]const u8,
    hls_bucket: ?[]const u8,
    /// Число опубликованных сегментов для формирования списка ключей удаления.
    segments: ?u32,
};

/// Владелец трека; kind различает пользовательскую и сервисную учётки.
pub const Owner = struct {
    id: []const u8,
    kind: []const u8,
};

/// Метаданные нового трека; файл загружается отдельным запросом.
pub const CreateTrack = struct {
    /// Дополнительные плейлисты; сервис также добавляет трек в Uploads пользователя.
    playlist_ids: []const []const u8 = &.{},
    title: []const u8,
    artist: []const u8,
};

/// Проверяет до 100 различных UUID плейлистов и возвращает метаданные с обрезанными пробелами.
/// Строки результата ссылаются на входные данные.
pub fn validateCreate(input: CreateTrack) !CreateTrack {
    if (input.playlist_ids.len > 100) return error.InvalidPlaylistIds;

    for (input.playlist_ids, 0..) |id, i| {
        if (!isValidId(id)) return error.InvalidPlaylistId;
        for (input.playlist_ids[0..i]) |previous| {
            if (std.ascii.eqlIgnoreCase(id, previous)) return error.DuplicatePlaylistId;
        }
    }

    return .{
        .playlist_ids = input.playlist_ids,
        .title = try validateText(input.title),
        .artist = try validateText(input.artist),
    };
}

/// Обрезает крайние пробелы и проверяет непустой UTF-8 текст до 256 символов без управляющих байт.
fn validateText(value: []const u8) ![]const u8 {
    const text = std.mem.trim(u8, value, " \t\r\n");
    if (text.len == 0 or text.len > 1024) return error.InvalidText;

    const count = std.unicode.utf8CountCodepoints(text) catch return error.InvalidText;
    if (count > 256) return error.InvalidText;

    for (text) |c| {
        if (c < 32 or c == 127) return error.InvalidText;
    }

    return text;
}

/// Проверяет строковую форму UUID с дефисами; версия и вариант UUID не ограничиваются.
pub fn isValidId(id: []const u8) bool {
    if (id.len != 36) return false;

    for (id, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }

    return true;
}

/// Возвращает разрешённый MIME-тип в нижнем регистре, игнорируя параметры заголовка; иначе null.
pub fn parseContentType(header: []const u8) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, header, ';') orelse header.len;
    const mime = std.mem.trim(u8, header[0..end], " \t");

    const allowed = [_][]const u8{
        "audio/mpeg",               "audio/flac",      "audio/x-flac", "audio/wav", "audio/x-wav",
        "audio/ogg",                "application/ogg", "audio/aac",    "audio/mp4", "audio/webm",
        "application/octet-stream",
    };

    for (allowed) |item| {
        if (std.ascii.eqlIgnoreCase(mime, item)) return item;
    }

    return null;
}

test "validate track metadata including Cyrillic and missing text" {
    const id = "11111111-1111-4111-8111-111111111111";

    const input = try validateCreate(.{ .playlist_ids = &.{id}, .title = "  Песня  ", .artist = "Исполнитель" });

    try std.testing.expectEqualStrings("Песня", input.title);
    try std.testing.expectError(error.InvalidText, validateCreate(.{ .playlist_ids = &.{id}, .title = " \t", .artist = "Artist" }));
    try std.testing.expectError(error.InvalidText, validateCreate(.{ .playlist_ids = &.{id}, .title = "bad\x00title", .artist = "Artist" }));
    try std.testing.expectError(error.InvalidText, validateCreate(.{ .playlist_ids = &.{id}, .title = "\xff", .artist = "Artist" }));
    try std.testing.expectError(error.InvalidText, validateCreate(.{ .playlist_ids = &.{id}, .title = "a" ** 257, .artist = "Artist" }));
}

test "IDs cannot inject object paths or SQL" {
    try std.testing.expect(isValidId("ABCDEF01-1234-5678-abcd-123456789012"));
    try std.testing.expect(!isValidId("../../file"));
    try std.testing.expect(!isValidId("11111111-1111-4111-8111-11111111111z"));
    try std.testing.expect(!isValidId("11111111/1111/4111/8111/111111111111"));
}

test "normalize allowed MIME types and reject multipart" {
    try std.testing.expectEqualStrings("audio/mpeg", parseContentType("Audio/MPEG; charset=binary").?);
    try std.testing.expect(parseContentType("multipart/form-data; boundary=test") == null);
    try std.testing.expect(parseContentType("text/html") == null);
}

test "playlist memberships require distinct valid UUIDs and a bounded list" {
    const id = "abcdef01-1234-5678-abcd-123456789012";
    const second = "11111111-1111-4111-8111-111111111111";

    const input = try validateCreate(.{ .playlist_ids = &.{ id, second }, .title = "Track", .artist = "Artist" });

    try std.testing.expectEqual(@as(usize, 2), input.playlist_ids.len);

    const empty = try validateCreate(.{ .playlist_ids = &.{}, .title = "Track", .artist = "Artist" });

    try std.testing.expectEqual(@as(usize, 0), empty.playlist_ids.len);
    try std.testing.expectError(error.InvalidPlaylistIds, validateCreate(.{ .playlist_ids = &([_][]const u8{id} ** 101), .title = "Track", .artist = "Artist" }));
    try std.testing.expectError(error.InvalidPlaylistId, validateCreate(.{ .playlist_ids = &.{ id, "bad" }, .title = "Track", .artist = "Artist" }));
    try std.testing.expectError(error.DuplicatePlaylistId, validateCreate(.{ .playlist_ids = &.{ id, id }, .title = "Track", .artist = "Artist" }));
    try std.testing.expectError(error.DuplicatePlaylistId, validateCreate(.{ .playlist_ids = &.{ id, "ABCDEF01-1234-5678-ABCD-123456789012" }, .title = "Track", .artist = "Artist" }));
}

test "track JSON allows omitted playlist_ids and an empty array" {
    for ([_][]const u8{
        "{\"title\":\"Track\",\"artist\":\"Artist\"}",
        "{\"playlist_ids\":[],\"title\":\"Track\",\"artist\":\"Artist\"}",
    }) |body| {
        const parsed = try std.json.parseFromSlice(CreateTrack, std.testing.allocator, body, .{});
        defer parsed.deinit();

        const input = try validateCreate(parsed.value);

        try std.testing.expectEqual(@as(usize, 0), input.playlist_ids.len);
    }
}
