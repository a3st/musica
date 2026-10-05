const std = @import("std");

pub const CreateTrack = struct {
    album_id: []const u8,
    title: []const u8,
    artist: []const u8,
};

pub fn validateCreate(input: CreateTrack) !CreateTrack {
    if (!validId(input.album_id)) return error.InvalidAlbumId;
    return .{
        .album_id = input.album_id,
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
    const input = try validateCreate(.{ .album_id = id, .title = "  Песня  ", .artist = "Исполнитель" });
    try std.testing.expectEqualStrings("Песня", input.title);
    try std.testing.expectError(error.InvalidText, validateCreate(.{ .album_id = id, .title = " \t", .artist = "Artist" }));
    try std.testing.expectError(error.InvalidText, validateCreate(.{ .album_id = id, .title = "bad\x00title", .artist = "Artist" }));
    try std.testing.expectError(error.InvalidText, validateCreate(.{ .album_id = id, .title = "\xff", .artist = "Artist" }));
    try std.testing.expectError(error.InvalidText, validateCreate(.{ .album_id = id, .title = "a" ** 257, .artist = "Artist" }));
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
