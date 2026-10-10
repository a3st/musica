const std = @import("std");
const tracks_model = @import("../tracks/model.zig");
const jobs_model = @import("../../infrastructure/jobs/model.zig");

/// Вид фоновой задачи конвертации исходного файла в HLS.
pub const preparation_job_kind = "prepare_hls";

/// Максимальное число сегментов в опубликованном HLS.
pub const max_segments = 10000;
/// Максимальный размер манифеста при чтении из S3, в байтах.
pub const max_manifest_bytes = 1024 * 1024;
/// Максимальный размер одного сегмента при чтении из S3, в байтах.
pub const max_segment_bytes = 2 * 1024 * 1024;

/// Данные задачи подготовки HLS с адресом исходного файла.
pub const Payload = struct {
    track_id: []const u8,
    bucket: []const u8,
    key: []const u8,
    /// Размер исходного файла в байтах.
    size: usize,
};

/// Состояние и исходный файл, прочитанные под блокировкой перед постановкой задачи.
pub const Input = struct {
    status: tracks_model.Status,
    payload: Payload,
};

/// Арендованная задача подготовки HLS с разобранным payload.
pub const Task = struct {
    job: jobs_model.Job,
    payload: Payload,
};

/// Состояние трека, подготовки и опубликованных файлов HLS.
pub const State = struct {
    status: tracks_model.Status,
    /// Состояние задачи подготовки; null, если задача ещё не создана.
    preparation: ?jobs_model.State,

    /// Бакет и префикс опубликованного HLS; null до публикации.
    bucket: ?[]const u8,
    prefix: ?[]const u8,
    /// Число опубликованных сегментов; null до публикации.
    segments: ?u32,
};

/// Разбирает имя segment-NNNNNN.ts и проверяет лимит номера сегмента; иначе null.
pub fn parseSegmentIndex(name: []const u8) ?u32 {
    if (name.len != 17 or
        !std.mem.startsWith(u8, name, "segment-") or
        !std.mem.endsWith(u8, name, ".ts")) return null;

    for (name[8..14]) |c| if (!std.ascii.isDigit(c)) return null;
    const index = std.fmt.parseInt(u32, name[8..14], 10) catch return null;
    if (index >= max_segments) return null;

    return index;
}

/// Проверяет завершённый VOD-манифест с последовательными номерами от нуля и возвращает число сегментов.
/// Пустой, незавершённый манифест или неверные имена — InvalidHlsOutput.
pub fn segmentCount(manifest: []const u8) !u32 {
    if (!std.mem.startsWith(u8, manifest, "#EXTM3U\n") or
        std.mem.indexOf(u8, manifest, "#EXT-X-ENDLIST\n") == null) return error.InvalidHlsOutput;

    var count: u32 = 0;
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if ((parseSegmentIndex(line) orelse return error.InvalidHlsOutput) != count) return error.InvalidHlsOutput;
        count += 1;
    }

    if (count == 0) return error.InvalidHlsOutput;

    return count;
}

/// Проверяет манифест и заменяет имена файлов на относительные адреса HTTP-сегментов.
/// Добавляет share_token при его наличии; токен должен быть заранее проверен, результат хранится в arena.
pub fn buildPlaybackManifest(
    arena: std.mem.Allocator,
    manifest: []const u8,
    token: ?[]const u8,
) ![]const u8 {
    _ = try segmentCount(manifest);

    var out: std.Io.Writer.Allocating = .init(arena);
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '#') {
            try out.writer.print("{s}\n", .{line});
        } else {
            try out.writer.print("segments/{s}", .{line});
            if (token) |value| try out.writer.print("?share_token={s}", .{value});
            try out.writer.writeByte('\n');
        }
    }

    return out.written();
}

test "HLS publication rejects incomplete playlists, traversal and missing segments" {
    const manifest = "#EXTM3U\n#EXTINF:6.0,\nsegment-000000.ts\n#EXTINF:2.0,\nsegment-000001.ts\n#EXT-X-ENDLIST\n";

    try std.testing.expectEqual(@as(u32, 2), try segmentCount(manifest));
    try std.testing.expectError(error.InvalidHlsOutput, segmentCount("#EXTM3U\nsegment-000000.ts\n"));
    try std.testing.expectError(error.InvalidHlsOutput, segmentCount("#EXTM3U\n../secret\n#EXT-X-ENDLIST\n"));
    try std.testing.expectError(error.InvalidHlsOutput, segmentCount("#EXTM3U\nsegment-000001.ts\n#EXT-X-ENDLIST\n"));
    try std.testing.expect(parseSegmentIndex("segment-010000.ts") == null);
    try std.testing.expect(parseSegmentIndex("segment-00000a.ts") == null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const body = try buildPlaybackManifest(arena.allocator(), manifest, "abc123");

    try std.testing.expect(std.mem.indexOf(u8, body, "segments/segment-000000.ts?share_token=abc123\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "segments/segment-000001.ts?share_token=abc123\n") != null);
}
