const std = @import("std");
const tracks = @import("../tracks/model.zig");

pub const JobState = enum { queued, processing, ready, failed };
pub const State = struct {
    status: tracks.TrackStatus,
    preparation: ?JobState,
    bucket: ?[]const u8,
    prefix: ?[]const u8,
    segments: ?u32,
};
pub const Job = struct {
    id: []const u8,
    attempt: []const u8,
    bucket: []const u8,
    key: []const u8,
    size: usize,
};
pub const max_segments = 10000;
pub const max_manifest_bytes = 1024 * 1024;
pub const max_segment_bytes = 2 * 1024 * 1024;

pub fn segmentIndex(name: []const u8) ?u32 {
    if (name.len != 17 or !std.mem.startsWith(u8, name, "segment-") or !std.mem.endsWith(u8, name, ".ts")) return null;
    for (name[8..14]) |c| if (!std.ascii.isDigit(c)) return null;
    const index = std.fmt.parseInt(u32, name[8..14], 10) catch return null;
    if (index >= max_segments) return null;
    return index;
}

// Only publish complete VOD playlists with contiguous, backend-generated names.
pub fn segmentCount(manifest: []const u8) !u32 {
    if (!std.mem.startsWith(u8, manifest, "#EXTM3U\n") or
        std.mem.indexOf(u8, manifest, "#EXT-X-ENDLIST\n") == null) return error.InvalidHlsOutput;
    var count: u32 = 0;
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if ((segmentIndex(line) orelse return error.InvalidHlsOutput) != count) return error.InvalidHlsOutput;
        count += 1;
    }
    if (count == 0) return error.InvalidHlsOutput;
    return count;
}

pub fn playbackManifest(arena: std.mem.Allocator, manifest: []const u8, token: ?[]const u8) ![]const u8 {
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
    try std.testing.expect(segmentIndex("segment-010000.ts") == null);
    try std.testing.expect(segmentIndex("segment-00000a.ts") == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try playbackManifest(arena.allocator(), manifest, "abc123");
    try std.testing.expect(std.mem.indexOf(u8, body, "segments/segment-000000.ts?share_token=abc123\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "segments/segment-000001.ts?share_token=abc123\n") != null);
}
