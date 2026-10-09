const std = @import("std");
const database = @import("../database.zig");
const tracks_model = @import("../../features/tracks/model.zig");

pub fn create(conn: *database.Connection, arena: std.mem.Allocator, user: []const u8, bucket: []const u8, input: tracks_model.CreateTrack) ![36]u8 {
    const id = (try conn.text(
        arena,
        "WITH new_track AS (SELECT gen_random_uuid() AS id) INSERT INTO musica.tracks (id, title, artist, owner_id, storage_bucket, object_key) SELECT id, $1, $2, $3, $4, 'tracks/' || id::text || '/source' FROM new_track RETURNING id::text",
        .{ input.title, input.artist, user, bucket },
    )) orelse return error.DatabaseUnavailable;
    if (!tracks_model.validId(id)) return error.DatabaseUnavailable;
    const result = id[0..36].*;
    if (try conn.exec("INSERT INTO musica.track_playlists (track_id, playlist_id) SELECT $1, id FROM musica.playlists WHERE owner_id = $2 AND is_default", .{ &result, user }) != 1)
        return error.DatabaseUnavailable;
    return result;
}

pub fn lockForDeletion(conn: *database.Connection, arena: std.mem.Allocator, user: []const u8, id: []const u8) !tracks_model.Files {
    const body = (conn.text(arena, "SELECT json_build_object('bucket',storage_bucket,'key',object_key,'prefix',hls_prefix,'hls_bucket',hls_bucket,'segments',hls_segment_count)::text FROM musica.tracks WHERE id=$1 AND owner_id=$2 FOR UPDATE NOWAIT", .{ id, user }) catch |err| {
        if (err == error.LockUnavailable) return error.UploadInProgress;
        return err;
    }) orelse return error.TrackNotFound;
    return std.json.parseFromSliceLeaky(tracks_model.Files, arena, body, .{}) catch error.DatabaseUnavailable;
}

pub fn remove(conn: *database.Connection, id: []const u8) !void {
    _ = try conn.exec("DELETE FROM musica.tracks WHERE id=$1", .{id});
}

pub fn lockForUpload(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8, user: []const u8) !tracks_model.UploadLocation {
    const body = (conn.text(arena, "SELECT json_build_object('bucket',storage_bucket,'key',object_key,'status',status)::text FROM musica.tracks WHERE id=$1 AND owner_id=$2 FOR UPDATE NOWAIT", .{ id, user }) catch |err| {
        if (err == error.LockUnavailable) return error.UploadInProgress;
        return err;
    }) orelse return error.TrackNotFound;
    const state = std.json.parseFromSliceLeaky(struct { bucket: []const u8, key: []const u8, status: tracks_model.Status }, arena, body, .{}) catch return error.DatabaseUnavailable;
    if (state.status != .pending) return error.AlreadyUploaded;
    return .{ .bucket = state.bucket, .key = state.key };
}

pub fn finishUpload(conn: *database.Connection, id: []const u8, key: []const u8, mime: []const u8, size: usize) !void {
    if (try conn.exec("UPDATE musica.tracks SET status='ready',object_key=$2,content_type=$3,size_bytes=$4,uploaded_at=now() WHERE id=$1 AND status='pending'", .{ id, key, mime, @as(i64, @intCast(size)) }) != 1) return error.UploadInProgress;
}

pub fn lock(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8) !void {
    _ = (try conn.text(arena, "SELECT id::text FROM musica.tracks WHERE id=$1 FOR UPDATE", .{id})) orelse return error.TrackNotFound;
}
