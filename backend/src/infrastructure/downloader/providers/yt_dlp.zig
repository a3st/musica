const std = @import("std");
const model = @import("../model.zig");

/// Ищет аудио через yt-dlp и сохраняет MP3 с метаданными и встроенной обложкой.
pub const YtDlp = struct {
    /// Заимствованный путь; должен жить дольше экземпляра YtDlp.
    path: []const u8,
    /// Заимствованный путь к FFmpeg для конвертации и встраивания обложки.
    ffmpeg_path: []const u8,
    /// Заимствованный адрес proxy; null сохраняет сетевые настройки yt-dlp по умолчанию.
    proxy: ?[]const u8,

    /// Сохраняет пути без выделения памяти; они должны жить дольше экземпляра.
    pub fn init(path: []const u8, ffmpeg_path: []const u8, proxy: ?[]const u8) YtDlp {
        return .{ .path = path, .ffmpeg_path = ffmpeg_path, .proxy = proxy };
    }

    /// Сохраняет source.mp3 в dir; при отмене останавливает процесс.
    /// Проверку метаданных, общий таймаут и удаление файлов выполняет вызывающий код.
    pub fn download(
        self: *const YtDlp,
        arena: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        request: model.Request,
        max_bytes: usize,
    ) !model.Result {
        var child = std.process.spawn(io, .{
            .argv = try self.buildArguments(arena, request, max_bytes),
            .cwd = .{ .dir = dir },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
            .create_no_window = true,
        }) catch |err| {
            std.log.err("Cannot launch yt-dlp at '{s}': {s}", .{ self.path, @errorName(err) });

            return err;
        };
        defer child.kill(io);

        switch (try child.wait(io)) {
            // yt-dlp exits with 101 after reaching --max-downloads, including a successful download.
            .exited => |code| if (code != 0 and code != 101) return error.DownloadFailed,
            else => return error.DownloadFailed,
        }

        return .{ .audio_path = "source.mp3", .content_type = "audio/mpeg" };
    }

    /// Формирует поиск до пяти кандидатов и сохранение одного MP3 256K с метаданными и обложкой.
    /// Поисковая строка передаётся одним аргументом без shell; результат выделяется в arena.
    fn buildArguments(
        self: *const YtDlp,
        arena: std.mem.Allocator,
        request: model.Request,
        max_bytes: usize,
    ) ![]const []const u8 {
        const query = try std.fmt.allocPrint(arena, "ytsearch5:{s} {s}", .{
            std.mem.trim(u8, request.artist, " \t\r\n"),
            std.mem.trim(u8, request.title, " \t\r\n"),
        });
        const max_size = try std.fmt.allocPrint(arena, "{d}", .{max_bytes});
        // No shell, user URL or filename is accepted; the search is always one argv element.
        const arguments = [_][]const u8{
            self.path,
            "--ignore-config",
            "--no-playlist",
            "--no-progress",
            "--no-abort-on-error",
            "--age-limit",
            "0",
            "--max-downloads",
            "1",
            "--socket-timeout",
            "30",
            "--retries",
            "2",
            "--max-filesize",
            max_size,
            "--js-runtimes",
            "node",

            "-f",
            "bestaudio/best",
            "-x",
            "--audio-format",
            "mp3",
            "--audio-quality",
            "256K",
            "--embed-metadata",
            "--embed-thumbnail",
            "--convert-thumbnails",
            "jpg",
            "--write-thumbnail",

            "--ffmpeg-location",
            self.ffmpeg_path,
            "--output",
            "source.%(ext)s",
            "--",
            query,
        };

        const proxy = self.proxy orelse return arena.dupe([]const u8, &arguments);
        const argv = try arena.alloc([]const u8, arguments.len + 2);
        const options_end = arguments.len - 2;
        @memcpy(argv[0..options_end], arguments[0..options_end]);
        argv[options_end] = "--proxy";
        argv[options_end + 1] = proxy;
        @memcpy(argv[options_end + 2 ..], arguments[options_end..]);

        return argv;
    }
};

test "yt-dlp uses fixed output, MP3 bitrate and artwork; search stays a single argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const provider = YtDlp.init("yt-dlp", "C:\\Program Files\\FFmpeg\\bin\\ffmpeg.exe", null);
    const argv = try provider.buildArguments(arena.allocator(), .{
        .title = "Title \"; echo hi",
        .artist = "Artist",
    }, 1024);
    try std.testing.expectEqualStrings("ytsearch5:Artist Title \"; echo hi", argv[argv.len - 1]);
    try std.testing.expectEqualStrings("--", argv[argv.len - 2]);

    var bitrate = false;
    var cover = false;
    var ffmpeg = false;
    var size_limit = false;
    for (argv, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "--audio-quality")) bitrate = std.mem.eql(u8, argv[index + 1], "256K");
        if (std.mem.eql(u8, arg, "--embed-thumbnail")) cover = true;
        if (std.mem.eql(u8, arg, "--ffmpeg-location")) ffmpeg = std.mem.eql(u8, argv[index + 1], provider.ffmpeg_path);
        if (std.mem.eql(u8, arg, "--max-filesize")) size_limit = std.mem.eql(u8, argv[index + 1], "1024");
    }

    try std.testing.expect(bitrate and cover and ffmpeg and size_limit);
}

test "yt-dlp keeps proxy credentials in one argument before the search separator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const proxy = "socks5://user:password@proxy.example.com:1080/?value=a&other=b";
    const provider = YtDlp.init("yt-dlp", "ffmpeg", proxy);
    const argv = try provider.buildArguments(arena.allocator(), .{
        .title = "Song",
        .artist = "Artist",
    }, 1024);

    try std.testing.expectEqualStrings("--proxy", argv[argv.len - 4]);
    try std.testing.expectEqualStrings(proxy, argv[argv.len - 3]);
    try std.testing.expectEqualStrings("--", argv[argv.len - 2]);
    try std.testing.expectEqualStrings("ytsearch5:Artist Song", argv[argv.len - 1]);

    const direct = YtDlp.init("yt-dlp", "ffmpeg", null);
    const direct_argv = try direct.buildArguments(arena.allocator(), .{
        .title = "Song",
        .artist = "Artist",
    }, 1024);
    for (direct_argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--proxy"));
}
