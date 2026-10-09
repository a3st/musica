const std = @import("std");
const database = @import("../database.zig");
const tracks_model = @import("../../features/tracks/model.zig");
const spotify_int_model = @import("../../features/spotify_int/model.zig");

pub fn status(conn: *database.Connection, arena: std.mem.Allocator, user: []const u8, id: []const u8) ![]const u8 {
    return (try conn.text(
        arena,
        "SELECT json_build_object('id',$2::text,'tracks',json_agg(json_build_object('id',j.payload->>'track_id','title',j.payload->'track'->>'title','artist',j.payload->'track'->>'artist','download',j.state,'status',t.status,'preparation',h.state) ORDER BY j.created_at,j.id))::text FROM public.jobs j LEFT JOIN musica.tracks t ON t.id::text=j.payload->>'track_id' LEFT JOIN public.jobs h ON h.kind='prepare_hls' AND h.dedupe_key=t.id::text WHERE j.kind=$3 AND j.payload->>'user_id'=$1 AND j.payload->>'import_id'=$2 HAVING count(*)>0",
        .{ user, id, spotify_int_model.download_job_kind },
    )) orelse error.NotFound;
}

pub fn trackStatus(conn: *database.Connection, arena: std.mem.Allocator, user: []const u8, id: []const u8) !tracks_model.Status {
    const value = (try conn.text(arena, "SELECT status::text FROM musica.tracks WHERE id=$1 AND owner_id=$2", .{ id, user })) orelse return error.TrackNotFound;
    return std.meta.stringToEnum(tracks_model.Status, value) orelse error.DatabaseUnavailable;
}

pub fn retry(conn: *database.Connection, user: []const u8, id: []const u8) !void {
    _ = try conn.exec("UPDATE public.jobs j SET state='queued',attempts=0,attempt_id=NULL,lease_until=NULL,available_at=clock_timestamp(),updated_at=clock_timestamp() WHERE kind=$3 AND state='failed' AND payload->>'user_id'=$1 AND payload->>'import_id'=$2 AND EXISTS (SELECT 1 FROM musica.tracks t WHERE t.id::text=j.payload->>'track_id' AND t.owner_id=$1::uuid)", .{ user, id, spotify_int_model.download_job_kind });
}
