const std = @import("std");
const model = @import("../model.zig");

/// Ищет аудио в SoundCloud через yt-dlp и сохраняет MP3 с метаданными и встроенной обложкой.
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
            .stdout = .inherit,
            .stderr = .inherit,
            .create_no_window = true,
        }) catch |err| {
            std.log.err("Cannot launch yt-dlp at '{s}': {s}", .{ self.path, @errorName(err) });

            return err;
        };
        defer child.kill(io);

        switch (try child.wait(io)) {
            // yt-dlp exits with 101 after reaching --max-downloads, including a successful download.
            .exited => |code| {
                if (code != 0 and code != 101) {
                    std.log.warn("yt-dlp exited with code {d}; see downloader output above", .{code});

                    return error.DownloadFailed;
                }
            },
            else => return error.DownloadFailed,
        }

        return .{ .audio_path = "source.mp3", .content_type = "audio/mpeg" };
    }

    /// Ищет до десяти треков SoundCloud, фильтрует название/исполнителя и сохраняет один MP3 256K.
    /// Поисковая строка передаётся одним аргументом без shell; результат выделяется в arena.
    fn buildArguments(
        self: *const YtDlp,
        arena: std.mem.Allocator,
        request: model.Request,
        max_bytes: usize,
    ) ![]const []const u8 {
        const query = try std.fmt.allocPrint(arena, "scsearch10:{s} {s}", .{
            std.mem.trim(u8, request.artist, " \t\r\n"),
            std.mem.trim(u8, request.title, " \t\r\n"),
        });
        const max_size = try std.fmt.allocPrint(arena, "{d}", .{max_bytes});
        const title_pattern = try matchPattern(arena, request.title);
        const artist_pattern = try matchPattern(arena, request.artist);
        const versions = try excludedVersions(arena, request.title);
        const filters = try arena.alloc([]const u8, 3);
        for ([_][]const u8{ "artist", "uploader", "title" }, filters) |field, *filter| {
            filter.* = try std.fmt.allocPrint(arena, "title ~= '{s}' & {s} ~= '{s}'{s}", .{
                title_pattern, field, artist_pattern, versions,
            });
        }
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
            "--match-filters",
            filters[0],
            "--match-filters",
            filters[1],
            "--match-filters",
            filters[2],

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

            "--output",
            "source.%(ext)s",
            "--",
            query,
        };

        // yt-dlp ищет стандартное имя в PATH; --ffmpeg-location принимает путь к файлу.
        const use_location = !std.mem.eql(u8, self.ffmpeg_path, "ffmpeg") and
            !std.mem.eql(u8, self.ffmpeg_path, "ffmpeg.exe");
        const extra_options: usize = (if (use_location) @as(usize, 2) else 0) +
            (if (self.proxy != null) @as(usize, 2) else 0);
        const argv = try arena.alloc([]const u8, arguments.len + extra_options);
        const options_end = arguments.len - 2;
        @memcpy(argv[0..options_end], arguments[0..options_end]);
        var offset = options_end;

        if (use_location) {
            argv[offset] = "--ffmpeg-location";
            argv[offset + 1] = self.ffmpeg_path;
            offset += 2;
        }
        if (self.proxy) |proxy| {
            argv[offset] = "--proxy";
            argv[offset + 1] = proxy;
            offset += 2;
        }
        @memcpy(argv[offset..], arguments[options_end..]);

        return argv;
    }
};

const word_separators = " \t\r\n-()[]{}.,!?\"'/\\:;|&+*^$=<>%#@`~";

/// Формирует безопасный Unicode-regex: слова сохраняют порядок, разделители могут отличаться.
fn matchPattern(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    var pattern: std.ArrayList(u8) = .empty;
    try pattern.appendSlice(arena, "(?i)(?<!\\w)");
    var words = std.mem.tokenizeAny(u8, value, word_separators);
    var count: usize = 0;
    while (words.next()) |word| {
        if (count > 0) try pattern.appendSlice(arena, "\\W+");
        try pattern.appendSlice(arena, word);
        count += 1;
    }
    if (count == 0) return error.TrackNotFound;
    try pattern.appendSlice(arena, "(?!\\w)");

    return pattern.toOwnedSlice(arena);
}

/// Исключает другие версии по маркерам в названии, сохраняя явно запрошенные Live/Remix и прочие варианты.
fn excludedVersions(arena: std.mem.Allocator, title: []const u8) ![]const u8 {
    var excluded: std.ArrayList(u8) = .empty;
    for ([_][]const u8{
        "remix",    "live",   "cover", "instrumental", "karaoke",
        "acoustic", "slowed", "sped",  "remaster",     "edit",
    }) |marker| {
        var words = std.mem.tokenizeAny(u8, title, word_separators);
        const requested = while (words.next()) |word| {
            if (std.ascii.eqlIgnoreCase(word, marker)) break true;
        } else false;
        if (requested) continue;

        if (excluded.items.len > 0) try excluded.append(arena, '|');
        try excluded.appendSlice(arena, marker);
    }
    if (excluded.items.len == 0) return "";

    return std.fmt.allocPrint(arena, " & title !~= '(?i)\\b({s})\\b'", .{excluded.items});
}

test "yt-dlp uses fixed output, MP3 bitrate and artwork; search stays a single argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const provider = YtDlp.init("yt-dlp", "C:\\Program Files\\FFmpeg\\bin\\ffmpeg.exe", null);
    const argv = try provider.buildArguments(arena.allocator(), .{
        .title = "Title \"; echo hi",
        .artist = "Artist",
    }, 1024);
    try std.testing.expectEqualStrings("scsearch10:Artist Title \"; echo hi", argv[argv.len - 1]);
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

test "SoundCloud matching preserves Unicode words and removes filter delimiters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const pattern = try matchPattern(arena.allocator(), "Серега Пират - ЧСВ ' & (Live)");
    try std.testing.expectEqualStrings("(?i)(?<!\\w)Серега\\W+Пират\\W+ЧСВ\\W+Live(?!\\w)", pattern);
    try std.testing.expectError(error.TrackNotFound, matchPattern(arena.allocator(), " & ' () "));
}

test "SoundCloud version filters retain requested versions without matching word fragments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const requested = try excludedVersions(arena.allocator(), "Song (LIVE Remix)");
    try std.testing.expect(std.mem.indexOf(u8, requested, "live") == null);
    try std.testing.expect(std.mem.indexOf(u8, requested, "remix") == null);
    try std.testing.expect(std.mem.indexOf(u8, requested, "cover") != null);

    const fragments = try excludedVersions(arena.allocator(), "Lively Remixed Song");
    try std.testing.expect(std.mem.indexOf(u8, fragments, "remix|live|cover") != null);
}

test "yt-dlp searches FFmpeg in PATH and preserves explicit Linux executable paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const request: model.Request = .{ .title = "Song", .artist = "Artist" };
    const from_path = YtDlp.init("yt-dlp", "ffmpeg", null);
    const path_argv = try from_path.buildArguments(arena.allocator(), request, 1024);
    for (path_argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--ffmpeg-location"));

    const executable = "/opt/media tools/ffmpeg";
    const explicit = YtDlp.init("yt-dlp", executable, null);
    const explicit_argv = try explicit.buildArguments(arena.allocator(), request, 1024);
    try std.testing.expectEqualStrings("--ffmpeg-location", explicit_argv[explicit_argv.len - 4]);
    try std.testing.expectEqualStrings(executable, explicit_argv[explicit_argv.len - 3]);
    try std.testing.expectEqualStrings("--", explicit_argv[explicit_argv.len - 2]);
    try std.testing.expectEqualStrings("scsearch10:Artist Song", explicit_argv[explicit_argv.len - 1]);
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
    try std.testing.expectEqualStrings("scsearch10:Artist Song", argv[argv.len - 1]);

    const direct = YtDlp.init("yt-dlp", "ffmpeg", null);
    const direct_argv = try direct.buildArguments(arena.allocator(), .{
        .title = "Song",
        .artist = "Artist",
    }, 1024);
    for (direct_argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--proxy"));
}
