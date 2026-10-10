const std = @import("std");
const Job = @import("../../infrastructure/jobs/model.zig").Job;

pub const upload_job_kind = "upload_track";
pub const cleanup_job_kind = "delete_s3_objects";

pub const UploadLocation = struct { bucket: []const u8, key: []const u8 };
pub const Status = enum { pending, ready, streamed };
pub const UploadPayload = struct { track_id: []const u8, bucket: []const u8, key: []const u8 };
pub const CleanupPayload = struct { bucket: []const u8, keys: []const []const u8 };
pub const CleanupTask = struct { job: Job, payload: CleanupPayload };
pub const Files = struct { bucket: []const u8, key: []const u8, prefix: ?[]const u8, hls_bucket: ?[]const u8, segments: ?u32 };

pub const Owner = struct {
    id: []const u8,
    kind: []const u8,
};

pub const CreateTrack = struct {
    playlist_ids: []const []const u8 = &.{},
    title: []const u8,
    artist: []const u8,
};

pub fn validateCreate(input: CreateTrack) !CreateTrack {
    if (input.playlist_ids.len > 100) return error.InvalidPlaylistIds;
    for (input.playlist_ids, 0..) |id, i| {
        if (!validId(id)) return error.InvalidPlaylistId;
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

pub fn validId(id: []const u8) bool {
    if (id.len != 36) return false;
    for (id, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

pub fn contentType(header: []const u8) ?[]const u8 {
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
    try std.testing.expect(validId("ABCDEF01-1234-5678-abcd-123456789012"));
    try std.testing.expect(!validId("../../file"));
    try std.testing.expect(!validId("11111111-1111-4111-8111-11111111111z"));
    try std.testing.expect(!validId("11111111/1111/4111/8111/111111111111"));
}

test "normalize allowed MIME types and reject multipart" {
    try std.testing.expectEqualStrings("audio/mpeg", contentType("Audio/MPEG; charset=binary").?);
    try std.testing.expect(contentType("multipart/form-data; boundary=test") == null);
    try std.testing.expect(contentType("text/html") == null);
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
