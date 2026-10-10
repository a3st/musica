const std = @import("std");
const model = @import("model.zig");

/// Читает технические метаданные аудио через настроенный исполняемый файл ffprobe.
pub const Probe = struct {
    /// Заимствованный путь; должен жить дольше экземпляра Probe.
    path: []const u8,

    /// Сохраняет путь без выделения памяти; освобождение ресурсов не требуется.
    pub fn init(path: []const u8) Probe {
        return .{ .path = path };
    }

    /// Читает длительность аудио и индекс встроенной обложки через ffprobe.
    /// Исходник разрешается относительно dir; таймаут и отменой управляет вызывающий код.
    pub fn inspect(
        self: *const Probe,
        arena: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        source_path: []const u8,
    ) !model.Metadata {
        const result = try std.process.run(arena, io, .{
            .argv = &.{
                self.path,
                "-v",
                "error",
                "-protocol_whitelist",
                "file,pipe",
                "-format_whitelist",
                "mp3,flac,wav,ogg,aac,mov,matroska,webm",
                "-show_entries",
                "format=duration:stream=index,codec_type:stream_disposition=attached_pic",
                "-of",
                "json",
                source_path,
            },
            .cwd = .{ .dir = dir },
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
            .create_no_window = true,
        });

        switch (result.term) {
            .exited => |code| if (code == 0) return parseMetadata(arena, result.stdout),
            else => {},
        }

        std.log.warn("FFprobe failed: {s}", .{result.stderr});

        return error.InvalidMedia;
    }
};

/// Проверяет ответ ffprobe; округляет секунды и исключает обычные видеодорожки из обложек.
fn parseMetadata(arena: std.mem.Allocator, body: []const u8) !model.Metadata {
    const Stream = struct {
        index: u32,
        codec_type: []const u8,
        disposition: struct { attached_pic: u8 = 0 } = .{},
    };

    const parsed = std.json.parseFromSliceLeaky(struct {
        format: struct { duration: ?[]const u8 = null } = .{},
        streams: []const Stream,
    }, arena, body, .{ .ignore_unknown_fields = true }) catch return error.InvalidMedia;

    var result: model.Metadata = .{ .duration_seconds = null, .artwork_stream = null };
    var audio = false;

    for (parsed.streams) |stream| {
        if (std.mem.eql(u8, stream.codec_type, "audio")) audio = true;
        if (std.mem.eql(u8, stream.codec_type, "video") and stream.disposition.attached_pic == 1 and result.artwork_stream == null)
            result.artwork_stream = stream.index;
    }
    if (!audio) return error.InvalidMedia;

    if (parsed.format.duration) |value| {
        const seconds = std.fmt.parseFloat(f64, value) catch return error.InvalidMedia;
        const rounded = @round(seconds);
        if (!std.math.isFinite(seconds) or seconds < 0 or rounded > std.math.maxInt(i32)) return error.InvalidMedia;
        result.duration_seconds = @intFromFloat(rounded);
    }

    return result;
}

test "probe rounds seconds and uses only attached artwork" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parseMetadata(arena.allocator(),
        \\{"format":{"duration":"182.6"},"streams":[{"index":0,"codec_type":"audio"},{"index":1,"codec_type":"video"},{"index":2,"codec_type":"video","disposition":{"attached_pic":1}}]}
    );
    try std.testing.expectEqual(@as(?u32, 183), result.duration_seconds);
    try std.testing.expectEqual(@as(?u32, 2), result.artwork_stream);

    const unknown = try parseMetadata(arena.allocator(), "{\"streams\":[{\"index\":0,\"codec_type\":\"audio\"}]}");
    try std.testing.expect(unknown.duration_seconds == null and unknown.artwork_stream == null);

    for ([_][]const u8{ "-1", "nan", "inf", "2147483648", "broken" }) |duration| {
        const body = try std.fmt.allocPrint(arena.allocator(), "{{\"format\":{{\"duration\":\"{s}\"}},\"streams\":[{{\"index\":0,\"codec_type\":\"audio\"}}]}}", .{duration});
        try std.testing.expectError(error.InvalidMedia, parseMetadata(arena.allocator(), body));
    }

    try std.testing.expectError(error.InvalidMedia, parseMetadata(arena.allocator(), "{\"streams\":[{\"index\":0,\"codec_type\":\"video\"}]}"));
}
