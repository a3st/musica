const std = @import("std");
const database = @import("../database.zig");
const tracks_model = @import("../../features/tracks/model.zig");
const web_int_model = @import("../../features/web_int/model.zig");

/// Возвращает JSON результата поиска, пока срок кеша не истёк.
pub fn readSearchCache(conn: *database.Connection, arena: std.mem.Allocator, key: []const u8) !?[]const u8 {
    return conn.queryText(arena, "SELECT body FROM musica.catalog_cache WHERE key = $1 AND expires_at > clock_timestamp()", .{key});
}

/// Обновляет общий кеш поиска на десять минут; устаревшие записи удаляются при записи.
pub fn writeSearchCache(conn: *database.Connection, key: []const u8, body: []const u8) !void {
    _ = try conn.exec("DELETE FROM musica.catalog_cache WHERE expires_at <= clock_timestamp()", .{});
    _ = try conn.exec(
        \\INSERT INTO musica.catalog_cache (key, body, expires_at)
        \\VALUES ($1, $2, clock_timestamp() + interval '10 minutes')
        \\ON CONFLICT (key) DO UPDATE SET body = EXCLUDED.body, expires_at = EXCLUDED.expires_at
    , .{ key, body });
}

/// Читает метаданные общего трека; личные треки здесь недоступны.
pub fn readPlaybackTrack(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8) !tracks_model.Track {
    const query =
        \\SELECT json_build_object('id', t.id, 'title', t.title, 'artist', t.artist,
        \\    'owner_id', t.owner_id, 'status', t.status, 'owner_kind', u.kind,
        \\    'duration_seconds', t.duration_seconds, 'artwork_key', t.artwork_key)::text
        \\FROM musica.tracks t JOIN musica.users u ON u.id = t.owner_id
        \\WHERE t.id = $1 AND u.kind = 'system'
    ;
    const body = (try conn.queryText(arena, query, .{id})) orelse return error.TrackNotFound;
    return std.json.parseFromSliceLeaky(tracks_model.Track, arena, body, .{});
}

/// Возвращает до 20 ID общих треков без пользовательских привязок дольше seconds.
/// Кандидаты не блокируются; перед удалением нужна повторная проверка.
pub fn listCleanupCandidates(conn: *database.Connection, arena: std.mem.Allocator, seconds: u32) ![]const []const u8 {
    const query =
        \\SELECT COALESCE(json_agg(id::text), '[]'::json)::text
        \\FROM (
        \\    SELECT id
        \\    FROM musica.tracks
        \\    WHERE catalog_key IS NOT NULL
        \\    AND orphaned_at <= clock_timestamp() - $1::integer * interval '1 second'
        \\    ORDER BY orphaned_at
        \\    LIMIT 20) t
    ;

    const body = (try conn.queryText(arena, query, .{seconds})) orelse return error.DatabaseUnavailable;

    return std.json.parseFromSliceLeaky([]const []const u8, arena, body, .{});
}

/// Блокирует сервисный трек и повторно проверяет срок хранения и отсутствие пользовательских привязок.
/// Возвращает ID владельца или null, если трек отсутствует либо не подлежит очистке.
pub fn lockForCleanup(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8, seconds: u32) !?[]const u8 {
    const track_query =
        \\SELECT t.owner_id::text
        \\FROM musica.tracks t
        \\JOIN musica.users u
        \\ON u.id = t.owner_id
        \\WHERE t.id = $1
        \\AND u.kind = 'system'
        \\FOR UPDATE OF t
    ;

    const owner = (try conn.queryText(arena, track_query, .{id})) orelse return null;

    const references_query =
        \\SELECT id::text
        \\FROM musica.tracks t
        \\WHERE t.id = $1
        \\AND orphaned_at <= clock_timestamp() - $2::integer * interval '1 second'
        \\AND NOT EXISTS (
        \\    SELECT 1
        \\    FROM musica.track_playlists tp
        \\    JOIN musica.playlists p
        \\    ON p.id = tp.playlist_id
        \\    JOIN musica.users u
        \\    ON u.id = p.owner_id
        \\    WHERE tp.track_id = t.id
        \\    AND u.kind = 'user')
    ;

    if (try conn.queryText(arena, references_query, .{ id, seconds }) == null) return null;
    return owner;
}

/// Ищет загруженные сервисные треки; слова передаются JSON-массивом и сравниваются буквально.
/// Личные и pending-треки исключены; порядок стабилен, результат ограничен 25 записями.
pub fn searchLocal(conn: *database.Connection, arena: std.mem.Allocator, words: []const u8) ![]const tracks_model.Track {
    const query =
        \\SELECT COALESCE(json_agg(row_to_json(result)), '[]'::json)::text
        \\FROM (
        \\    SELECT t.id::text, t.title, t.artist, t.owner_id::text, t.status::text,
        \\        u.kind AS owner_kind, t.duration_seconds, t.artwork_key
        \\    FROM musica.tracks t JOIN musica.users u ON u.id = t.owner_id
        \\    WHERE u.kind = 'system' AND t.status IN ('ready', 'streamed')
        \\    AND NOT EXISTS (
        \\        SELECT 1 FROM jsonb_array_elements_text($1::jsonb) AS words(word)
        \\        WHERE strpos(lower(t.title || ' ' || t.artist), lower(words.word)) = 0)
        \\    ORDER BY lower(t.title), lower(t.artist), t.id
        \\    LIMIT 25
        \\) result
    ;
    const body = (try conn.queryText(arena, query, .{words})) orelse return error.DatabaseUnavailable;
    return std.json.parseFromSliceLeaky([]const tracks_model.Track, arena, body, .{}) catch error.DatabaseUnavailable;
}

/// Исключает повторы каталога по источнику или исполнителю и полному названию среди локальных результатов.
/// Нормализация совпадает с созданием треков; Live и Remix сохраняются, порядок каталога не меняется.
pub fn deduplicateSearchResults(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    local: []const web_int_model.Track,
    catalog: []const web_int_model.SearchTrack,
) ![]const web_int_model.SearchTrack {
    if (catalog.len == 0) return &.{};

    const ids = try arena.alloc([]const u8, local.len);
    for (local, ids) |track, *id| id.* = track.id;

    const query =
        \\SELECT COALESCE(json_agg(result.item ORDER BY result.position), '[]'::json)::text
        \\FROM (
        \\    SELECT item, position,
        \\        row_number() OVER (PARTITION BY musica.track_identity(item->>'artist', item->>'title')
        \\            ORDER BY position) AS occurrence
        \\    FROM jsonb_array_elements($1::jsonb) WITH ORDINALITY AS entries(item, position)
        \\) result
        \\WHERE result.occurrence = 1 AND NOT EXISTS (
        \\    SELECT 1 FROM musica.tracks t
        \\    WHERE t.id IN (SELECT value::uuid FROM jsonb_array_elements_text($2::jsonb))
        \\    AND (t.catalog_key = musica.track_identity(result.item->>'artist', result.item->>'title')
        \\        OR EXISTS (SELECT 1 FROM musica.track_sources s
        \\            WHERE s.track_id = t.id AND s.provider = result.item->>'provider'
        \\            AND s.external_id = result.item->>'external_id')))
    ;
    const body = (try conn.queryText(arena, query, .{
        try std.json.Stringify.valueAlloc(arena, catalog, .{}),
        try std.json.Stringify.valueAlloc(arena, ids, .{}),
    })) orelse return error.DatabaseUnavailable;

    return std.json.parseFromSliceLeaky([]const web_int_model.SearchTrack, arena, body, .{}) catch error.DatabaseUnavailable;
}
