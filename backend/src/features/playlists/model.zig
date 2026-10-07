const std = @import("std");

pub const Visibility = enum { private, public, unlisted };
pub const Role = enum { viewer, editor };

pub const CreatePlaylist = struct {
    title: []const u8,
    description: []const u8 = "",
    tags: []const []const u8 = &.{},
    visibility: Visibility = .private,
};

pub fn validateCreate(input: CreatePlaylist) !CreatePlaylist {
    const title = try validateText(input.title, 256, false);
    const description = try validateText(input.description, 4096, true);
    if (input.tags.len > 32) return error.InvalidTags;
    for (input.tags, 0..) |tag, i| {
        const normalized = validateText(tag, 64, false) catch return error.InvalidTags;
        // Tags are stored as supplied, so reject surrounding whitespace.
        if (normalized.len != tag.len) return error.InvalidTags;
        for (input.tags[0..i]) |previous| {
            if (std.ascii.eqlIgnoreCase(tag, previous)) return error.InvalidTags;
        }
    }
    return .{ .title = title, .description = description, .tags = input.tags, .visibility = input.visibility };
}

fn validateText(value: []const u8, max_length: usize, allow_empty: bool) ![]const u8 {
    const text = std.mem.trim(u8, value, " \t\r\n");
    if ((!allow_empty and text.len == 0) or text.len > max_length * 4) return error.InvalidPlaylistMetadata;
    const length = std.unicode.utf8CountCodepoints(text) catch return error.InvalidPlaylistMetadata;
    if (length > max_length) return error.InvalidPlaylistMetadata;
    for (text) |c| {
        if (c == 127 or (c < 32 and !(allow_empty and (c == '\n' or c == '\r' or c == '\t'))))
            return error.InvalidPlaylistMetadata;
    }
    return text;
}

test "playlist JSON defaults to private with empty description and tags" {
    const parsed = try std.json.parseFromSlice(CreatePlaylist, std.testing.allocator, "{\"title\":\" Playlist \"}", .{});
    defer parsed.deinit();
    const input = try validateCreate(parsed.value);
    try std.testing.expectEqualStrings("Playlist", input.title);
    try std.testing.expectEqual(Visibility.private, input.visibility);
    try std.testing.expectEqual(@as(usize, 0), input.tags.len);
    try std.testing.expectEqualStrings("", input.description);
}

test "playlist metadata rejects invalid text and duplicate or malformed tags" {
    try std.testing.expectError(error.InvalidPlaylistMetadata, validateCreate(.{ .title = " " }));
    try std.testing.expectError(error.InvalidPlaylistMetadata, validateCreate(.{ .title = "\xff" }));
    try std.testing.expectError(error.InvalidPlaylistMetadata, validateCreate(.{ .title = "a" ** 257 }));
    try std.testing.expectError(error.InvalidTags, validateCreate(.{ .title = "Playlist", .tags = &.{ "rock", "ROCK" } }));
    try std.testing.expectError(error.InvalidTags, validateCreate(.{ .title = "Playlist", .tags = &.{" rock "} }));
    try std.testing.expectError(error.InvalidTags, validateCreate(.{ .title = "Playlist", .tags = &.{""} }));
    _ = try validateCreate(.{ .title = "Playlist", .description = "First line\nSecond line", .tags = &.{ "rock", "live" }, .visibility = .unlisted });
}
