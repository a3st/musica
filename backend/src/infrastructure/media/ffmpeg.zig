const std = @import("std");

/// Обрабатывает локальные медиафайлы через настроенный исполняемый файл FFmpeg.
pub const FFmpeg = struct {
    /// Заимствованный путь; должен жить дольше экземпляра FFmpeg.
    path: []const u8,

    /// Сохраняет путь без выделения памяти; освобождение ресурсов не требуется.
    pub fn init(path: []const u8) FFmpeg {
        return .{ .path = path };
    }

    /// Извлекает встроенную обложку в JPEG размером до 600 × 600 с сохранением пропорций.
    /// Пути разрешаются относительно dir; таймаут и отменой управляет вызывающий код.
    pub fn extractArtwork(
        self: *const FFmpeg,
        arena: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        source_path: []const u8,
        stream_index: u32,
        output_path: []const u8,
    ) !void {
        const stream = try std.fmt.allocPrint(arena, "0:{d}", .{stream_index});
        const result = try std.process.run(arena, io, .{
            .argv = &.{
                self.path,
                "-hide_banner",
                "-loglevel",
                "error",
                "-nostdin",
                "-y",
                "-protocol_whitelist",
                "file,pipe",
                "-format_whitelist",
                "mp3,flac,wav,ogg,aac,mov,matroska,webm",
                "-i",
                source_path,
                "-map",
                stream,
                "-frames:v",
                "1",
                "-an",
                "-sn",
                "-dn",
                "-vf",
                "scale=600:600:force_original_aspect_ratio=decrease",
                "-q:v",
                "3",
                "-threads",
                "1",
                "-filter_threads",
                "1",
                output_path,
            },
            .cwd = .{ .dir = dir },
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
            .create_no_window = true,
        });

        switch (result.term) {
            .exited => |code| if (code == 0) return,
            else => {},
        }

        std.log.warn("FFmpeg artwork extraction failed: {s}", .{result.stderr});

        return error.InvalidMedia;
    }

    /// Создаёт VOD-манифест и шестисекундные MPEG-TS сегменты: AAC 192 kbit/s, stereo, 48 kHz.
    /// Пути разрешаются относительно dir; при отмене останавливает процесс, таймаут задаёт вызывающий код.
    pub fn prepareHls(
        self: *const FFmpeg,
        io: std.Io,
        dir: std.Io.Dir,
        source_path: []const u8,
        manifest_path: []const u8,
        segment_pattern: []const u8,
    ) !void {
        var child = try spawnFfmpeg(io, .{
            .argv = &.{
                self.path,
                "-hide_banner",
                "-loglevel",
                "error",
                "-nostdin",
                "-y",

                "-protocol_whitelist",
                "file,pipe",
                "-format_whitelist",
                "mp3,flac,wav,ogg,aac,mov,matroska,webm",
                "-i",
                source_path,
                "-map",
                "0:a:0",
                "-vn",
                "-sn",
                "-dn",

                "-threads",
                "1",
                "-filter_threads",
                "1",
                "-c:a",
                "aac",
                "-b:a",
                "192k",
                "-ac",
                "2",
                "-ar",
                "48000",

                "-f",
                "hls",
                "-hls_time",
                "6",
                "-hls_playlist_type",
                "vod",
                "-hls_list_size",
                "0",
                "-hls_segment_filename",
                segment_pattern,
                manifest_path,
            },
            .cwd = .{ .dir = dir },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
            .create_no_window = true,
        });
        defer child.kill(io);

        const term = try child.wait(io);
        switch (term) {
            .exited => |code| if (code != 0) return error.TranscodingFailed,
            else => return error.TranscodingFailed,
        }
    }
};

/// Запускает FFmpeg без shell; отсутствие исполняемого файла переводит в FfmpegNotFound.
fn spawnFfmpeg(io: std.Io, options: std.process.SpawnOptions) !std.process.Child {
    return std.process.spawn(io, options) catch |err| {
        if (err == error.Canceled) return err;
        std.log.warn(
            "Cannot launch FFmpeg at '{s}': {s}. FFMPEG_PATH must name an executable file, not its directory.",
            .{ options.argv[0], @errorName(err) },
        );
        if (err == error.FileNotFound) return error.FfmpegNotFound;

        return err;
    };
}

test "missing FFmpeg executable has a distinct preparation error" {
    const ffmpeg = FFmpeg.init("musica-nonexistent-ffmpeg-0f87633b/ffmpeg");

    try std.testing.expectError(error.FfmpegNotFound, ffmpeg.prepareHls(
        std.testing.io,
        std.Io.Dir.cwd(),
        "source",
        "index.m3u8",
        "segment-%06d.ts",
    ));
}
