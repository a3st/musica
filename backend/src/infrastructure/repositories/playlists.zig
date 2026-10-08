const std = @import("std");
const database = @import("../database.zig");

const json_playlist =
    \\json_build_object('id', a.id, 'owner_id', a.owner_id, 'title', a.title,
    \\'description', a.description, 'tags', a.tags, 'visibility', a.visibility,
    \\'is_default', a.is_default, 'image_key', a.image_key,
    \\'tracks', COALESCE((SELECT json_agg(json_build_object('id', t.id, 'title', t.title,
    \\'artist', t.artist, 'status', t.status, 'owner_id', t.owner_id) ORDER BY t.created_at, t.id)
    \\FROM musica.tracks t JOIN musica.track_playlists ta ON ta.track_id = t.id WHERE ta.playlist_id = a.id), '[]'::json))::text
;

pub fn list(conn: *database.Connection, arena: std.mem.Allocator, user: []const u8) ![]const u8 {
    return (try conn.text(arena, "SELECT COALESCE(json_agg(item ORDER BY is_default DESC, title, id), '[]'::json)::text FROM (SELECT a.id,a.title,a.is_default,json_build_object('id',a.id,'owner_id',a.owner_id,'title',a.title,'description',a.description,'visibility',a.visibility,'is_default',a.is_default,'image_key',a.image_key,'role',CASE WHEN a.owner_id=$1 THEN 'owner' ELSE m.role END,'track_count',(SELECT count(*) FROM musica.track_playlists tp WHERE tp.playlist_id=a.id)) AS item FROM musica.playlists a LEFT JOIN musica.playlist_members m ON m.playlist_id=a.id AND m.user_id=$1 WHERE a.owner_id=$1 OR m.user_id=$1) accessible", .{user})) orelse error.DatabaseUnavailable;
}

pub fn create(conn: *database.Connection, arena: std.mem.Allocator, user: []const u8, title: []const u8, description: []const u8, tags: []const u8, visibility: []const u8) ![]const u8 {
    return (try conn.text(
        arena,
        "INSERT INTO musica.playlists (owner_id, title, description, tags, visibility) VALUES ($1, $2, $3, $4::jsonb, $5) RETURNING id::text",
        .{ user, title, description, tags, visibility },
    )) orelse error.DatabaseUnavailable;
}

pub fn read(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8, user: ?[]const u8) ![]const u8 {
    return (try conn.text(
        arena,
        "SELECT " ++ json_playlist ++ " FROM musica.playlists a WHERE a.id = $1 AND a.owner_id IS NOT NULL AND (a.visibility = 'public' OR a.owner_id = $2::uuid OR EXISTS (SELECT 1 FROM musica.playlist_members m WHERE m.playlist_id = a.id AND m.user_id = $2::uuid))",
        .{ id, user },
    )) orelse error.NotFound;
}

pub fn readShared(conn: *database.Connection, arena: std.mem.Allocator, hash: []const u8) ![]const u8 {
    return (try conn.text(
        arena,
        "SELECT " ++ json_playlist ++ " FROM musica.playlists a WHERE a.visibility = 'unlisted' AND a.share_token_hash = $1 AND a.owner_id IS NOT NULL",
        .{hash},
    )) orelse error.NotFound;
}

pub fn requireWrite(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8, user: []const u8, owner_only: bool) !void {
    _ = (try conn.text(
        arena,
        "SELECT a.id::text FROM musica.playlists a WHERE a.id = $1 AND (a.owner_id = $2 OR (NOT $3 AND EXISTS (SELECT 1 FROM musica.playlist_members m WHERE m.playlist_id = a.id AND m.user_id = $2 AND m.role = 'editor'))) FOR UPDATE OF a",
        .{ id, user, owner_only },
    )) orelse return error.NotFound;
}

pub fn update(conn: *database.Connection, id: []const u8, title: []const u8, description: []const u8, tags: []const u8, visibility: []const u8) !void {
    _ = try conn.exec(
        "UPDATE musica.playlists SET title = $2, description = $3, tags = $4::jsonb, visibility = $5, share_token_hash = CASE WHEN $5 = 'unlisted' THEN share_token_hash ELSE NULL END WHERE id = $1",
        .{ id, title, description, tags, visibility },
    );
}

pub fn setMemberRole(conn: *database.Connection, id: []const u8, user: []const u8, role: []const u8) !void {
    _ = try conn.exec("INSERT INTO musica.playlist_members (playlist_id, user_id, role) VALUES ($1, $2, $3) ON CONFLICT (playlist_id, user_id) DO UPDATE SET role = EXCLUDED.role", .{ id, user, role });
}

pub fn removeMember(conn: *database.Connection, id: []const u8, user: []const u8) !void {
    _ = try conn.exec("DELETE FROM musica.playlist_members WHERE playlist_id = $1 AND user_id = $2", .{ id, user });
}

pub fn setLink(conn: *database.Connection, id: []const u8, hash: ?[]const u8) !void {
    if (try conn.exec("UPDATE musica.playlists SET share_token_hash = $2 WHERE id = $1 AND visibility = 'unlisted' AND NOT is_default", .{ id, hash }) != 1) return error.InvalidInput;
}

pub fn isDefault(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8) !bool {
    return (try conn.text(arena, "SELECT id::text FROM musica.playlists WHERE id=$1 AND is_default", .{id})) != null;
}

pub fn containsTrack(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8, track_id: []const u8) !void {
    _ = (try conn.text(arena, "SELECT track_id::text FROM musica.track_playlists WHERE playlist_id=$1 AND track_id=$2", .{ id, track_id })) orelse return error.TrackNotFound;
}

pub fn addTrack(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8, user: []const u8, track_id: []const u8) !void {
    _ = (try conn.text(arena, "SELECT id::text FROM musica.tracks WHERE id=$1 AND owner_id=$2 FOR UPDATE", .{ track_id, user })) orelse return error.TrackNotFound;
    _ = try conn.exec("INSERT INTO musica.track_playlists (playlist_id,track_id) VALUES ($1,$2) ON CONFLICT DO NOTHING", .{ id, track_id });
}

pub fn removeTrack(conn: *database.Connection, id: []const u8, track_id: []const u8) !void {
    if (try conn.exec("DELETE FROM musica.track_playlists WHERE playlist_id=$1 AND track_id=$2", .{ id, track_id }) != 1) return error.TrackNotFound;
}

pub fn setImage(conn: *database.Connection, id: []const u8, key: []const u8) !void {
    if (try conn.exec("UPDATE musica.playlists SET image_key=$2 WHERE id=$1", .{ id, key }) != 1) return error.NotFound;
}

pub fn remove(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8) !?[]const u8 {
    _ = try conn.exec("DELETE FROM musica.track_playlists WHERE playlist_id=$1", .{id});
    const body = (try conn.text(arena, "DELETE FROM musica.playlists WHERE id=$1 AND NOT is_default RETURNING json_build_object('image_key',image_key)::text", .{id})) orelse return error.NotFound;
    const files = std.json.parseFromSliceLeaky(struct { image_key: ?[]const u8 }, arena, body, .{}) catch return error.DatabaseUnavailable;
    return files.image_key;
}
