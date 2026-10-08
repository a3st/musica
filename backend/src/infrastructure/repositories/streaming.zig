const std = @import("std");
const database = @import("../database.zig");
const streaming_model = @import("../../features/streaming/model.zig");

const state_json =
    \\json_build_object('status', t.status, 'preparation', NULL,
    \\'bucket', t.hls_bucket, 'prefix', t.hls_prefix, 'segments', t.hls_segment_count)::text
;

pub fn read(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8, user: ?[]const u8, share_hash: ?[]const u8) !streaming_model.State {
    const body = (try conn.text(arena, "SELECT " ++ state_json ++ " FROM musica.tracks t WHERE t.id = $1 AND t.owner_id IS NOT NULL AND (t.owner_id = $2::uuid OR EXISTS (SELECT 1 FROM musica.track_playlists tp JOIN musica.playlists p ON p.id = tp.playlist_id WHERE tp.track_id = t.id AND p.owner_id IS NOT NULL AND (p.visibility = 'public' OR p.owner_id = $2::uuid OR EXISTS (SELECT 1 FROM musica.playlist_members m WHERE m.playlist_id = p.id AND m.user_id = $2::uuid) OR (p.visibility = 'unlisted' AND p.share_token_hash = $3)))) FOR SHARE OF t", .{ id, user, share_hash })) orelse return error.TrackNotFound;
    return std.json.parseFromSliceLeaky(streaming_model.State, arena, body, .{}) catch error.DatabaseUnavailable;
}

pub fn preparation(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8, user: []const u8) !streaming_model.PreparationState {
    const body = (try conn.text(arena, "SELECT json_build_object('status',status,'payload',json_build_object('track_id',id,'bucket',storage_bucket,'key',object_key,'size',COALESCE(size_bytes,0)))::text FROM musica.tracks WHERE id=$1 AND owner_id=$2 FOR UPDATE", .{ id, user })) orelse return error.TrackNotFound;
    return std.json.parseFromSliceLeaky(streaming_model.PreparationState, arena, body, .{}) catch error.DatabaseUnavailable;
}

pub fn finish(conn: *database.Connection, track_id: []const u8, bucket: []const u8, prefix: []const u8, segments: u32) !void {
    if (try conn.exec("UPDATE musica.tracks SET status='streamed',hls_bucket=$2,hls_prefix=$3,hls_segment_count=$4 WHERE id=$1 AND status='ready'", .{ track_id, bucket, prefix, segments }) != 1) return error.LeaseLost;
}
