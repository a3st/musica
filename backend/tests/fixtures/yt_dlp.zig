const std = @import("std");

// Offline executable used instead of yt-dlp. It verifies argv, waits for test
// control and produces a bounded file, without accessing any external service.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var bitrate = false;
    var thumbnail = false;
    var ffmpeg = false;
    var output = false;
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--audio-quality")) bitrate = std.mem.eql(u8, args[i + 1], "256K");
        if (std.mem.eql(u8, arg, "--embed-thumbnail")) thumbnail = true;
        if (std.mem.eql(u8, arg, "--ffmpeg-location")) ffmpeg = args[i + 1].len > 0;
        if (std.mem.eql(u8, arg, "--output")) output = std.mem.eql(u8, args[i + 1], "source.%(ext)s");
    }
    if (!bitrate or !thumbnail or !ffmpeg or !output or !std.mem.startsWith(u8, args[args.len - 1], "ytsearch1:")) return error.InvalidArguments;
    const control = init.environ_map.get("SPOTIFY_FIXTURE_CONTROL") orelse return error.MissingControl;
    while (true) {
        const data = try std.Io.Dir.cwd().readFileAlloc(init.io, control, init.gpa, .limited(100));
        defer init.gpa.free(data);
        if (std.mem.eql(u8, data, "fail")) return error.FixtureFailure;
        if (std.mem.eql(u8, data, "go")) break;
        try std.Io.sleep(init.io, .fromMilliseconds(100), .awake);
    }
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "source.mp3", .data = "ID3-offline-spotify-audio-fixture" });
}
