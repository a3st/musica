const std = @import("std");
const Connection = @import("../database.zig").Connection;
const Job = @import("model.zig").Job;

const json_job = "json_build_object('id',j.id,'kind',j.kind,'dedupe_key',j.dedupe_key,'state',j.state,'attempt_id',j.attempt_id,'attempts',j.attempts,'max_attempts',j.max_attempts,'lease_until',(extract(epoch FROM j.lease_until)*1000)::bigint,'available_at',(extract(epoch FROM j.available_at)*1000)::bigint,'created_at',(extract(epoch FROM j.created_at)*1000)::bigint,'updated_at',(extract(epoch FROM j.updated_at)*1000)::bigint,'payload',j.payload)::text";

fn decode(arena: std.mem.Allocator, body: []const u8) !Job {
    return std.json.parseFromSliceLeaky(Job, arena, body, .{}) catch error.DatabaseUnavailable;
}

pub fn enqueue(conn: *Connection, arena: std.mem.Allocator, kind: []const u8, dedupe_key: []const u8, payload: anytype, delay_seconds: u32, max_attempts: ?u32) !Job {
    const encoded = try std.json.Stringify.valueAlloc(arena, payload, .{});
    // Completed or active jobs are preserved. Explicit enqueue can restart a failed job.
    _ = try conn.exec("INSERT INTO public.jobs AS j (kind,dedupe_key,payload,available_at,max_attempts) VALUES ($1,$2,$3::jsonb,clock_timestamp()+$4::integer*interval '1 second',$5) ON CONFLICT (kind,dedupe_key) DO UPDATE SET payload=EXCLUDED.payload,state='queued',attempt_id=NULL,attempts=0,lease_until=NULL,available_at=EXCLUDED.available_at,max_attempts=EXCLUDED.max_attempts,updated_at=clock_timestamp() WHERE j.state='failed'", .{ kind, dedupe_key, encoded, delay_seconds, max_attempts });
    return (try find(conn, arena, kind, dedupe_key, false)) orelse error.DatabaseUnavailable;
}

pub fn insert(conn: *Connection, arena: std.mem.Allocator, kind: []const u8, payload: anytype, delay_seconds: u32, max_attempts: ?u32) !Job {
    const encoded = try std.json.Stringify.valueAlloc(arena, payload, .{});
    const body = (try conn.text(arena, "INSERT INTO public.jobs AS j (kind,payload,available_at,max_attempts) VALUES ($1,$2::jsonb,clock_timestamp()+$3::integer*interval '1 second',$4) RETURNING " ++ json_job, .{ kind, encoded, delay_seconds, max_attempts })) orelse return error.DatabaseUnavailable;
    return try decode(arena, body);
}

pub fn find(conn: *Connection, arena: std.mem.Allocator, kind: []const u8, key: []const u8, lock: bool) !?Job {
    const body = (try conn.text(arena, if (lock) "SELECT " ++ json_job ++ " FROM public.jobs j WHERE kind=$1 AND dedupe_key=$2 FOR UPDATE" else "SELECT " ++ json_job ++ " FROM public.jobs j WHERE kind=$1 AND dedupe_key=$2", .{ kind, key })) orelse return null;
    return try decode(arena, body);
}

pub fn claim(conn: *Connection, arena: std.mem.Allocator, kind: []const u8, lease_seconds: u32) !?Job {
    const body = (try conn.text(arena, "WITH candidate AS (SELECT id FROM public.jobs WHERE kind=$1 AND ((state='queued' AND available_at<=clock_timestamp()) OR (state='processing' AND lease_until<=clock_timestamp())) ORDER BY available_at,created_at FOR UPDATE SKIP LOCKED LIMIT 1) UPDATE public.jobs j SET state='processing',attempt_id=gen_random_uuid(),attempts=attempts+1,lease_until=clock_timestamp()+$2::integer*interval '1 second',updated_at=clock_timestamp() FROM candidate c WHERE j.id=c.id RETURNING " ++ json_job, .{ kind, lease_seconds })) orelse return null;
    return try decode(arena, body);
}

// For work performed synchronously by the caller rather than picked up by a worker.
pub fn acquire(conn: *Connection, arena: std.mem.Allocator, kind: []const u8, key: []const u8, attempt: []const u8, payload: anytype, lease_seconds: u32) !Job {
    const encoded = try std.json.Stringify.valueAlloc(arena, payload, .{});
    const body = (try conn.text(arena, "INSERT INTO public.jobs AS j (kind,dedupe_key,state,attempt_id,attempts,lease_until,payload) VALUES ($1,$2,'processing',$3,1,clock_timestamp()+$5::integer*interval '1 second',$4::jsonb) ON CONFLICT (kind,dedupe_key) DO UPDATE SET state='processing',attempt_id=EXCLUDED.attempt_id,attempts=j.attempts+1,lease_until=EXCLUDED.lease_until,payload=EXCLUDED.payload,updated_at=clock_timestamp() WHERE j.state<>'processing' OR j.lease_until<=clock_timestamp() RETURNING " ++ json_job, .{ kind, key, attempt, encoded, lease_seconds })) orelse return error.LeaseLost;
    return try decode(arena, body);
}

pub fn heartbeat(conn: *Connection, job: Job, lease_seconds: u32) !void {
    if (try conn.exec("UPDATE public.jobs SET lease_until=clock_timestamp()+$3::integer*interval '1 second',updated_at=clock_timestamp() WHERE id=$1 AND attempt_id=$2 AND state='processing' AND lease_until>clock_timestamp()", .{ job.id, job.attempt_id, lease_seconds }) != 1) return error.LeaseLost;
}

pub fn complete(conn: *Connection, job: Job) !void {
    if (try conn.exec("UPDATE public.jobs SET state='completed',lease_until=NULL,updated_at=clock_timestamp() WHERE id=$1 AND attempt_id=$2 AND state='processing' AND lease_until>clock_timestamp()", .{ job.id, job.attempt_id }) != 1) return error.LeaseLost;
}

pub fn fail(conn: *Connection, job: Job, retry: bool, delay_seconds: u32) !void {
    if (try conn.exec("UPDATE public.jobs SET state=CASE WHEN $3 AND (max_attempts IS NULL OR attempts<max_attempts) THEN 'queued' ELSE 'failed' END,lease_until=NULL,available_at=clock_timestamp()+$4::integer*interval '1 second',updated_at=clock_timestamp() WHERE id=$1 AND attempt_id=$2 AND state='processing' AND lease_until>clock_timestamp()", .{ job.id, job.attempt_id, retry, delay_seconds }) != 1) return error.LeaseLost;
}

pub fn deleteOwned(conn: *Connection, job: Job) !void {
    if (try conn.exec("DELETE FROM public.jobs WHERE id=$1 AND attempt_id=$2 AND state='processing' AND lease_until>clock_timestamp()", .{ job.id, job.attempt_id }) != 1) return error.LeaseLost;
}

pub fn cancelScheduled(conn: *Connection, id: []const u8) !void {
    if (try conn.exec("DELETE FROM public.jobs WHERE id=$1 AND state='queued' AND available_at>clock_timestamp()", .{id}) != 1) return error.LeaseLost;
}

pub fn removeByKey(conn: *Connection, kind: []const u8, key: []const u8) !void {
    _ = try conn.exec("DELETE FROM public.jobs WHERE kind=$1 AND dedupe_key=$2", .{ kind, key });
}

pub fn isActive(conn: *Connection, arena: std.mem.Allocator, id: []const u8) !bool {
    return (try conn.text(arena, "SELECT id::text FROM public.jobs WHERE id=$1 AND state='processing' AND lease_until>clock_timestamp()", .{id})) != null;
}
