const std = @import("std");
const database = @import("../database.zig");
const Job = @import("model.zig").Job;

const json_job =
    \\json_build_object(
    \\    'id', j.id,
    \\    'kind', j.kind,
    \\    'dedupe_key', j.dedupe_key,
    \\    'state', j.state,
    \\    'attempt_id', j.attempt_id,
    \\    'attempts', j.attempts,
    \\    'max_attempts', j.max_attempts,
    \\    'lease_until', (extract(epoch FROM j.lease_until) * 1000)::bigint,
    \\    'available_at', (extract(epoch FROM j.available_at) * 1000)::bigint,
    \\    'created_at', (extract(epoch FROM j.created_at) * 1000)::bigint,
    \\    'updated_at', (extract(epoch FROM j.updated_at) * 1000)::bigint,
    \\    'payload', j.payload
    \\)::text
;

/// Разбирает JSON записи jobs; некорректные данные переводит в DatabaseUnavailable.
fn decode(arena: std.mem.Allocator, body: []const u8) !Job {
    return std.json.parseFromSliceLeaky(Job, arena, body, .{}) catch error.DatabaseUnavailable;
}

/// Ставит задачу в очередь по kind/dedupe_key или повторяет failed-задачу.
/// Существующие queued, processing и completed задачи сохраняются.
pub fn enqueue(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    kind: []const u8,
    dedupe_key: []const u8,
    payload: anytype,
    delay_seconds: u32,
    max_attempts: ?u32,
) !Job {
    const encoded = try std.json.Stringify.valueAlloc(arena, payload, .{});

    const query =
        \\INSERT INTO public.jobs AS j(kind, dedupe_key, payload, available_at, max_attempts)
        \\VALUES ($1, $2, $3::jsonb, clock_timestamp() + $4::integer * interval '1 second',
        \\    $5)
        \\ON CONFLICT (kind, dedupe_key)
        \\DO UPDATE
        \\SET payload = EXCLUDED.payload, state = 'queued', attempt_id = NULL, attempts = 0,
        \\lease_until = NULL, available_at = EXCLUDED.available_at, max_attempts = EXCLUDED.max_attempts,
        \\updated_at = clock_timestamp()
        \\WHERE j.state = 'failed'
    ;

    _ = try conn.exec(query, .{ kind, dedupe_key, encoded, delay_seconds, max_attempts });
    return (try findByKey(conn, arena, kind, dedupe_key)) orelse error.DatabaseUnavailable;
}

/// Создаёт новую задачу в очереди без ключа дедупликации, с указанной задержкой.
pub fn enqueueNew(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    kind: []const u8,
    payload: anytype,
    delay_seconds: u32,
    max_attempts: ?u32,
) !Job {
    const encoded = try std.json.Stringify.valueAlloc(arena, payload, .{});

    const query =
        \\INSERT INTO public.jobs AS j(kind, payload, available_at, max_attempts)
        \\VALUES ($1, $2::jsonb, clock_timestamp() + $3::integer * interval '1 second', $4)
        \\RETURNING
    ++ " " ++ json_job;

    const body = (try conn.queryText(arena, query, .{ kind, encoded, delay_seconds, max_attempts })) orelse return error.DatabaseUnavailable;

    return try decode(arena, body);
}

/// Возвращает задачу по kind/dedupe_key без блокировки; null, если она отсутствует.
pub fn findByKey(conn: *database.Connection, arena: std.mem.Allocator, kind: []const u8, key: []const u8) !?Job {
    const query = "SELECT " ++ json_job ++ " FROM public.jobs j WHERE kind = $1 AND dedupe_key = $2";

    const body = (try conn.queryText(arena, query, .{ kind, key })) orelse return null;

    return try decode(arena, body);
}

/// Возвращает задачу по kind/dedupe_key с блокировкой FOR UPDATE; null, если она отсутствует.
pub fn lockByKey(conn: *database.Connection, arena: std.mem.Allocator, kind: []const u8, key: []const u8) !?Job {
    const query = "SELECT " ++ json_job ++ " FROM public.jobs j WHERE kind = $1 AND dedupe_key = $2 FOR UPDATE";

    const body = (try conn.queryText(arena, query, .{ kind, key })) orelse return null;

    return try decode(arena, body);
}

/// Атомарно арендует готовую queued-задачу или processing-задачу с истёкшей арендой.
/// Создаёт новую попытку, пропускает заблокированные строки; null, если работы нет.
pub fn claim(conn: *database.Connection, arena: std.mem.Allocator, kind: []const u8, lease_seconds: u32) !?Job {
    const query =
        \\WITH candidate AS (
        \\    SELECT id
        \\    FROM public.jobs
        \\    WHERE kind = $1
        \\    AND ((state = 'queued'
        \\            AND available_at <= clock_timestamp())
        \\        OR (state = 'processing'
        \\            AND lease_until <= clock_timestamp()))
        \\    ORDER BY available_at, created_at
        \\    FOR UPDATE SKIP LOCKED
        \\    LIMIT 1
        \\)
        \\UPDATE public.jobs j
        \\SET state = 'processing', attempt_id = gen_random_uuid(), attempts = attempts + 1,
        \\lease_until = clock_timestamp() + $2::integer * interval '1 second', updated_at = clock_timestamp()
        \\FROM candidate c
        \\WHERE j.id = c.id
        \\RETURNING
    ++ " " ++ json_job;

    const body = (try conn.queryText(arena, query, .{ kind, lease_seconds })) orelse return null;

    return try decode(arena, body);
}

/// Создаёт или арендует задачу для выполнения текущим запросом, сразу в processing.
/// Действующую чужую аренду не перехватывает; при конфликте возвращает LeaseLost.
pub fn acquireLease(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    kind: []const u8,
    key: []const u8,
    attempt: []const u8,
    payload: anytype,
    lease_seconds: u32,
) !Job {
    const encoded = try std.json.Stringify.valueAlloc(arena, payload, .{});

    const query =
        \\INSERT INTO public.jobs AS j(kind, dedupe_key, state, attempt_id, attempts, lease_until,
        \\    payload)
        \\VALUES ($1, $2, 'processing', $3, 1, clock_timestamp() + $5::integer * interval '1 second',
        \\    $4::jsonb)
        \\ON CONFLICT (kind, dedupe_key)
        \\DO UPDATE
        \\SET state = 'processing', attempt_id = EXCLUDED.attempt_id, attempts = j.attempts + 1,
        \\lease_until = EXCLUDED.lease_until, payload = EXCLUDED.payload, updated_at = clock_timestamp()
        \\WHERE j.state <> 'processing'
        \\OR j.lease_until <= clock_timestamp()
        \\RETURNING
    ++ " " ++ json_job;

    const body = (try conn.queryText(arena, query, .{ kind, key, attempt, encoded, lease_seconds })) orelse return error.LeaseLost;

    return try decode(arena, body);
}

/// Продлевает действующую аренду текущей попытки по часам БД; иначе LeaseLost.
pub fn heartbeat(conn: *database.Connection, job: Job, lease_seconds: u32) !void {
    const query =
        \\UPDATE public.jobs
        \\SET lease_until = clock_timestamp() + $3::integer * interval '1 second', updated_at = clock_timestamp()
        \\WHERE id = $1
        \\AND attempt_id = $2
        \\AND state = 'processing'
        \\AND lease_until > clock_timestamp()
    ;

    if (try conn.exec(query, .{ job.id, job.attempt_id, lease_seconds }) != 1) return error.LeaseLost;
}

/// Помечает задачу completed при совпадении попытки и действующей аренде; иначе LeaseLost.
pub fn complete(conn: *database.Connection, job: Job) !void {
    const query =
        \\UPDATE public.jobs
        \\SET state = 'completed', lease_until = NULL, updated_at = clock_timestamp()
        \\WHERE id = $1
        \\AND attempt_id = $2
        \\AND state = 'processing'
        \\AND lease_until > clock_timestamp()
    ;

    if (try conn.exec(query, .{ job.id, job.attempt_id }) != 1) return error.LeaseLost;
}

/// Повторно ставит задачу в очередь с задержкой, если разрешён retry и не исчерпан лимит; иначе failed.
/// Требует текущую попытку и действующую аренду; иначе LeaseLost.
pub fn fail(conn: *database.Connection, job: Job, retry: bool, delay_seconds: u32) !void {
    const query =
        \\UPDATE public.jobs
        \\SET state = CASE
        \\WHEN $3
        \\AND (max_attempts IS NULL
        \\    OR attempts < max_attempts) THEN 'queued'
        \\ELSE 'failed'
        \\END, lease_until = NULL, available_at = clock_timestamp() + $4::integer * interval '1 second',
        \\updated_at = clock_timestamp()
        \\WHERE id = $1
        \\AND attempt_id = $2
        \\AND state = 'processing'
        \\AND lease_until > clock_timestamp()
    ;

    if (try conn.exec(query, .{ job.id, job.attempt_id, retry, delay_seconds }) != 1) return error.LeaseLost;
}

/// Удаляет задачу при совпадении попытки и действующей аренде; иначе LeaseLost.
pub fn removeLeased(conn: *database.Connection, job: Job) !void {
    const query =
        \\DELETE
        \\FROM public.jobs
        \\WHERE id = $1
        \\AND attempt_id = $2
        \\AND state = 'processing'
        \\AND lease_until > clock_timestamp()
    ;

    if (try conn.exec(query, .{ job.id, job.attempt_id }) != 1) return error.LeaseLost;
}

/// Удаляет queued-задачу, время запуска которой ещё не наступило; иначе LeaseLost.
pub fn cancelScheduled(conn: *database.Connection, id: []const u8) !void {
    const query = "DELETE FROM public.jobs WHERE id = $1 AND state = 'queued' AND available_at > clock_timestamp()";

    if (try conn.exec(query, .{id}) != 1) return error.LeaseLost;
}

/// Удаляет задачу по kind/dedupe_key независимо от состояния и аренды.
/// Проверку активной работы выполняет вызывающий сервис.
pub fn removeByKey(conn: *database.Connection, kind: []const u8, key: []const u8) !void {
    const query = "DELETE FROM public.jobs WHERE kind = $1 AND dedupe_key = $2";

    _ = try conn.exec(query, .{ kind, key });
}

/// Проверяет состояние processing и действующую аренду задачи по часам БД.
pub fn isActive(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8) !bool {
    const query =
        \\SELECT id::text
        \\FROM public.jobs
        \\WHERE id = $1
        \\AND state = 'processing'
        \\AND lease_until > clock_timestamp()
    ;

    return (try conn.queryText(arena, query, .{id})) != null;
}
