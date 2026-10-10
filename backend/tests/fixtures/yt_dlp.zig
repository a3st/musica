const std = @import("std");

/// Проверяет аргументы вместо yt-dlp, ожидает команду теста и создаёт файл без обращения к сети.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    try validateArguments(args);

    const control_path = init.environ_map.get("DOWNLOAD_FIXTURE_CONTROL") orelse return error.MissingControl;
    try waitForControl(init.io, init.gpa, control_path);

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = "source.mp3",
        .data = "ID3-offline-spotify-audio-fixture",
    });
    // Match yt-dlp stopping after the first successful --max-downloads result.
    std.process.exit(101);
}

/// Проверяет параметры MP3, обложки, FFmpeg и фиксированного имени выходного файла.
fn validateArguments(args: []const []const u8) !void {
    if (args.len < 2) return error.InvalidArguments;

    var bitrate = false;
    var thumbnail = false;
    var ffmpeg = false;
    var output = false;
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--audio-quality") or
            std.mem.eql(u8, arg, "--ffmpeg-location") or
            std.mem.eql(u8, arg, "--output"))
        {
            if (i + 1 >= args.len) return error.InvalidArguments;
        }

        if (std.mem.eql(u8, arg, "--audio-quality")) bitrate = std.mem.eql(u8, args[i + 1], "256K");
        if (std.mem.eql(u8, arg, "--embed-thumbnail")) thumbnail = true;
        if (std.mem.eql(u8, arg, "--ffmpeg-location")) ffmpeg = args[i + 1].len > 0;
        if (std.mem.eql(u8, arg, "--output")) output = std.mem.eql(u8, args[i + 1], "source.%(ext)s");
    }

    if (!bitrate or !thumbnail or !ffmpeg or !output or
        !std.mem.startsWith(u8, args[args.len - 1], "ytsearch5:")) return error.InvalidArguments;
}

/// Ожидает go или fail из управляющего файла; временный буфер освобождается на каждой итерации.
fn waitForControl(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    while (true) {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(100));
        defer allocator.free(data);

        if (std.mem.eql(u8, data, "fail")) return error.FixtureFailure;
        if (std.mem.eql(u8, data, "go")) break;
        try std.Io.sleep(io, .fromMilliseconds(100), .awake);
    }
}
