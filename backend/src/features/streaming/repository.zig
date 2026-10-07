const std = @import("std");
const pg = @import("pg");
const sql = @import("../../helpers/sql.zig");
const model = @import("model.zig");

const state_json =
    \\json_build_object('status', t.status, 'preparation', j.state,
    \\'bucket', t.hls_bucket, 'prefix', t.hls_prefix, 'segments', t.hls_segment_count)::text
;

pub fn read(pool: *pg.Pool, arena: std.mem.Allocator, id: []const u8, user: ?[]const u8, share_hash: ?[]const u8) !model.State {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    const body = (try sql.text(conn, arena, "SELECT " ++ state_json ++ " FROM tracks t LEFT JOIN track_hls_jobs j ON j.track_id = t.id WHERE t.id = $1 AND t.owner_id IS NOT NULL AND (t.owner_id = $2::uuid OR EXISTS (SELECT 1 FROM track_playlists tp JOIN playlists p ON p.id = tp.playlist_id WHERE tp.track_id = t.id AND p.owner_id IS NOT NULL AND (p.visibility = 'public' OR p.owner_id = $2::uuid OR EXISTS (SELECT 1 FROM playlist_members m WHERE m.playlist_id = p.id AND m.user_id = $2::uuid) OR (p.visibility = 'unlisted' AND p.share_token_hash = $3))))", .{ id, user, share_hash })) orelse return error.TrackNotFound;
    return std.json.parseFromSliceLeaky(model.State, arena, body, .{}) catch error.DatabaseUnavailable;
}

pub fn enqueue(pool: *pg.Pool, arena: std.mem.Allocator, id: []const u8, user: []const u8) !model.State {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    conn.begin() catch return error.DatabaseUnavailable;
    errdefer conn.rollback() catch {};
    const status = (try sql.text(conn, arena, "SELECT status::text FROM tracks WHERE id=$1 AND owner_id=$2 FOR UPDATE", .{ id, user })) orelse return error.TrackNotFound;
    if (std.mem.eql(u8, status, "pending")) return error.TrackNotUploaded;
    if (std.mem.eql(u8, status, "ready")) {
        _ = try sql.exec(conn, "INSERT INTO track_hls_jobs (track_id) VALUES ($1) ON CONFLICT (track_id) DO UPDATE SET state='queued', attempts=0, attempt_id=NULL, lease_until=NULL, available_at=now(), updated_at=now() WHERE track_hls_jobs.state='failed'", .{id});
    }
    const body = (try sql.text(conn, arena, "SELECT " ++ state_json ++ " FROM tracks t LEFT JOIN track_hls_jobs j ON j.track_id=t.id WHERE t.id=$1", .{id})) orelse return error.DatabaseUnavailable;
    const result = std.json.parseFromSliceLeaky(model.State, arena, body, .{}) catch return error.DatabaseUnavailable;
    conn.commit() catch return error.DatabaseUnavailable;
    return result;
}

pub fn claim(pool: *pg.Pool, arena: std.mem.Allocator) !?model.Job {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    const body = (try sql.text(conn, arena, "WITH candidate AS (SELECT j.track_id FROM track_hls_jobs j JOIN tracks t ON t.id=j.track_id WHERE t.status='ready' AND ((j.state='queued' AND j.available_at<=now()) OR (j.state='processing' AND j.lease_until<now())) ORDER BY j.created_at FOR UPDATE OF j SKIP LOCKED LIMIT 1), claimed AS (UPDATE track_hls_jobs j SET state='processing', attempt_id=gen_random_uuid(), attempts=attempts+1, lease_until=now()+interval '60 seconds', updated_at=now() FROM candidate c WHERE j.track_id=c.track_id RETURNING j.track_id,j.attempt_id) SELECT json_build_object('id',t.id,'attempt',c.attempt_id,'bucket',t.storage_bucket,'key',t.object_key,'size',t.size_bytes)::text FROM claimed c JOIN tracks t ON t.id=c.track_id", .{})) orelse return null;
    return std.json.parseFromSliceLeaky(model.Job, arena, body, .{}) catch error.DatabaseUnavailable;
}

pub fn heartbeat(pool: *pg.Pool, job: model.Job) !void {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    if (try sql.exec(conn, "UPDATE track_hls_jobs SET lease_until=now()+interval '60 seconds', updated_at=now() WHERE track_id=$1 AND attempt_id=$2 AND state='processing' AND lease_until>now()", .{ job.id, job.attempt }) != 1) return error.LeaseLost;
}

pub fn finish(pool: *pg.Pool, job: model.Job, prefix: []const u8, segments: u32) !void {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    conn.begin() catch return error.DatabaseUnavailable;
    errdefer conn.rollback() catch {};
    if (try sql.exec(conn, "UPDATE tracks SET status='streamed', hls_bucket=$2, hls_prefix=$3, hls_segment_count=$4 WHERE id=$1 AND status='ready'", .{ job.id, job.bucket, prefix, segments }) != 1) return error.LeaseLost;
    if (try sql.exec(conn, "UPDATE track_hls_jobs SET state='ready', lease_until=NULL, updated_at=now() WHERE track_id=$1 AND attempt_id=$2 AND state='processing' AND lease_until>now()", .{ job.id, job.attempt }) != 1) return error.LeaseLost;
    conn.commit() catch return error.DatabaseUnavailable;
}

pub fn failed(pool: *pg.Pool, job: model.Job, retry: bool) !void {
    const conn = pool.acquire() catch return error.DatabaseUnavailable;
    defer conn.release();
    _ = try sql.exec(conn, "UPDATE track_hls_jobs SET state=CASE WHEN $3 AND attempts<3 THEN 'queued'::hls_job_state ELSE 'failed'::hls_job_state END, lease_until=NULL, available_at=now()+interval '30 seconds', updated_at=now() WHERE track_id=$1 AND attempt_id=$2 AND state='processing' AND lease_until>now()", .{ job.id, job.attempt, retry });
}
