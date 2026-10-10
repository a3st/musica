const std = @import("std");
const database = @import("../database.zig");

const json_playlist =
    \\json_build_object(
    \\    'id', a.id,
    \\    'owner_id', a.owner_id,
    \\    'title', a.title,
    \\    'description', a.description,
    \\    'tags', a.tags,
    \\    'visibility', a.visibility,
    \\    'is_default', a.is_default,
    \\    'image_key', a.image_key,
    \\    'track_count', (SELECT count(*) FROM musica.track_playlists tp WHERE tp.playlist_id = a.id),
    \\    'duration_seconds', (
    \\        SELECT CASE WHEN count(*) = 0 THEN 0 ELSE sum(t.duration_seconds) END
    \\        FROM musica.tracks t JOIN musica.track_playlists tp ON tp.track_id = t.id
    \\        WHERE tp.playlist_id = a.id),
    \\    'duration_complete', NOT EXISTS (
    \\        SELECT 1 FROM musica.tracks t JOIN musica.track_playlists tp ON tp.track_id = t.id
    \\        WHERE tp.playlist_id = a.id AND t.duration_seconds IS NULL),
    \\    'tracks', COALESCE((
    \\        SELECT json_agg(json_build_object(
    \\            'id', t.id,
    \\            'title', t.title,
    \\            'artist', t.artist,
    \\            'status', t.status,
    \\            'duration_seconds', t.duration_seconds,
    \\            'artwork_key', t.artwork_key,
    \\            'owner_id', t.owner_id,
    \\            'owner_kind', (
    \\                SELECT u.kind FROM musica.users u
    \\                WHERE u.id = t.owner_id
    \\            )
    \\        ) ORDER BY t.created_at, t.id)
    \\        FROM musica.tracks t
    \\        JOIN musica.track_playlists ta ON ta.track_id = t.id
    \\        WHERE ta.playlist_id = a.id
    \\    ), '[]'::json)
    \\)::text
;

/// Возвращает JSON списка собственных и доступных по членству плейлистов с ролями и числом треков.
pub fn list(conn: *database.Connection, arena: std.mem.Allocator, user: []const u8) ![]const u8 {
    const query =
        \\SELECT COALESCE(json_agg(item
        \\        ORDER BY is_default DESC, title, id), '[]'::json)::text
        \\FROM (
        \\    SELECT a.id, a.title, a.is_default, json_build_object('id', a.id, 'owner_id', a.owner_id,
        \\        'title', a.title, 'description', a.description, 'visibility', a.visibility, 'is_default',
        \\        a.is_default, 'image_key', a.image_key, 'role', CASE
        \\        WHEN a.owner_id = $1 THEN 'owner'
        \\        ELSE m.role
        \\        END, 'track_count', (
        \\            SELECT count(*)
        \\            FROM musica.track_playlists tp
        \\            WHERE tp.playlist_id = a.id), 'duration_seconds', (
        \\            SELECT CASE WHEN count(*) = 0 THEN 0 ELSE sum(t.duration_seconds) END
        \\            FROM musica.tracks t JOIN musica.track_playlists tp ON tp.track_id = t.id
        \\            WHERE tp.playlist_id = a.id), 'duration_complete', NOT EXISTS (
        \\            SELECT 1 FROM musica.tracks t JOIN musica.track_playlists tp ON tp.track_id = t.id
        \\            WHERE tp.playlist_id = a.id AND t.duration_seconds IS NULL)) AS item
        \\    FROM musica.playlists a
        \\    LEFT JOIN musica.playlist_members m
        \\    ON m.playlist_id = a.id
        \\    AND m.user_id = $1
        \\    WHERE a.owner_id = $1
        \\    OR m.user_id = $1) accessible
    ;

    return (try conn.queryText(arena, query, .{user})) orelse error.DatabaseUnavailable;
}

/// Создаёт плейлист с заданными деталями и возвращает его ID.
pub fn create(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    user: []const u8,
    title: []const u8,
    description: []const u8,
    tags: []const u8,
    visibility: []const u8,
) ![]const u8 {
    const query =
        \\INSERT INTO musica.playlists(owner_id, title, description, tags, visibility)
        \\VALUES ($1, $2, $3, $4::jsonb, $5)
        \\RETURNING id::text
    ;

    return (try conn.queryText(
        arena,
        query,
        .{ user, title, description, tags, visibility },
    )) orelse error.DatabaseUnavailable;
}

/// Возвращает JSON плейлиста с треками, проверяя публичность, владение или членство; иначе NotFound.
pub fn read(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8, user: ?[]const u8) ![]const u8 {
    const query =
        "SELECT " ++ json_playlist ++
        \\ FROM musica.playlists a
        \\WHERE a.id = $1
        \\AND a.owner_id IS NOT NULL
        \\AND (a.visibility = 'public'
        \\    OR a.owner_id = $2::uuid
        \\    OR EXISTS (
        \\        SELECT 1
        \\        FROM musica.playlist_members m
        \\        WHERE m.playlist_id = a.id
        \\        AND m.user_id = $2::uuid))
        ;

    return (try conn.queryText(
        arena,
        query,
        .{ id, user },
    )) orelse error.NotFound;
}

/// Возвращает JSON unlisted-плейлиста по хешу ссылки; иначе NotFound.
pub fn readShared(conn: *database.Connection, arena: std.mem.Allocator, hash: []const u8) ![]const u8 {
    const query =
        "SELECT " ++ json_playlist ++
        \\ FROM musica.playlists a
        \\WHERE a.visibility = 'unlisted'
        \\AND a.share_token_hash = $1
        \\AND a.owner_id IS NOT NULL
        ;

    return (try conn.queryText(
        arena,
        query,
        .{hash},
    )) orelse error.NotFound;
}

/// Проверяет права владельца или редактора и блокирует плейлист; owner_only исключает редакторов.
/// Если плейлист отсутствует или недоступен, возвращает NotFound.
pub fn lockForWrite(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    id: []const u8,
    user: []const u8,
    owner_only: bool,
) !void {
    const query =
        \\SELECT a.id::text
        \\FROM musica.playlists a
        \\WHERE a.id = $1
        \\AND (a.owner_id = $2
        \\    OR (NOT $3
        \\        AND EXISTS (
        \\            SELECT 1
        \\            FROM musica.playlist_members m
        \\            WHERE m.playlist_id = a.id
        \\            AND m.user_id = $2
        \\            AND m.role = 'editor')))
        \\FOR UPDATE OF a
    ;

    _ = (try conn.queryText(
        arena,
        query,
        .{ id, user, owner_only },
    )) orelse return error.NotFound;
}

/// Обновляет детали плейлиста и сбрасывает ссылку при выходе из режима unlisted.
pub fn update(
    conn: *database.Connection,
    id: []const u8,
    title: []const u8,
    description: []const u8,
    tags: []const u8,
    visibility: []const u8,
) !void {
    const query =
        \\UPDATE musica.playlists
        \\SET title = $2, description = $3, tags = $4::jsonb, visibility = $5, share_token_hash = CASE
        \\WHEN $5 = 'unlisted' THEN share_token_hash
        \\ELSE NULL
        \\END
        \\WHERE id = $1
    ;

    _ = try conn.exec(
        query,
        .{ id, title, description, tags, visibility },
    );
}

/// Добавляет участника плейлиста или меняет его роль.
pub fn setMemberRole(conn: *database.Connection, id: []const u8, user: []const u8, role: []const u8) !void {
    const query =
        \\INSERT INTO musica.playlist_members(playlist_id, user_id, role)
        \\VALUES ($1, $2, $3)
        \\ON CONFLICT (playlist_id, user_id)
        \\DO UPDATE
        \\SET role = EXCLUDED.role
    ;

    _ = try conn.exec(query, .{ id, user, role });
}

/// Удаляет участника плейлиста; отсутствие участника допустимо.
pub fn removeMember(conn: *database.Connection, id: []const u8, user: []const u8) !void {
    const query = "DELETE FROM musica.playlist_members WHERE playlist_id = $1 AND user_id = $2";

    _ = try conn.exec(query, .{ id, user });
}

/// Устанавливает или сбрасывает хеш ссылки обычного unlisted-плейлиста; иначе InvalidInput.
pub fn setLink(conn: *database.Connection, id: []const u8, hash: ?[]const u8) !void {
    const query =
        \\UPDATE musica.playlists
        \\SET share_token_hash = $2
        \\WHERE id = $1
        \\AND visibility = 'unlisted'
        \\AND NOT is_default
    ;

    if (try conn.exec(query, .{ id, hash }) != 1) return error.InvalidInput;
}

/// Проверяет, является ли плейлист дефолтным; для отсутствующего возвращает false.
pub fn isDefault(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8) !bool {
    const query = "SELECT id::text FROM musica.playlists WHERE id = $1 AND is_default";

    return (try conn.queryText(arena, query, .{id})) != null;
}

/// Проверяет привязку трека к плейлисту; иначе TrackNotFound.
pub fn requireTrack(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8, track_id: []const u8) !void {
    const query = "SELECT track_id::text FROM musica.track_playlists WHERE playlist_id = $1 AND track_id = $2";

    _ = (try conn.queryText(arena, query, .{ id, track_id })) orelse return error.TrackNotFound;
}

/// Блокирует собственный или сервисный трек и добавляет привязку без дублей.
/// Права на изменение плейлиста проверяет вызывающий сервис.
pub fn addTrack(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    id: []const u8,
    user: []const u8,
    track_id: []const u8,
) !void {
    const track_query =
        \\SELECT t.id::text
        \\FROM musica.tracks t
        \\JOIN musica.users u
        \\ON u.id = t.owner_id
        \\WHERE t.id = $1
        \\AND (t.owner_id = $2
        \\    OR u.kind = 'system')
        \\FOR UPDATE OF t
    ;

    _ = (try conn.queryText(arena, track_query, .{ track_id, user })) orelse return error.TrackNotFound;

    const link_query = "INSERT INTO musica.track_playlists(playlist_id, track_id) VALUES ($1, $2) ON CONFLICT DO NOTHING";

    _ = try conn.exec(link_query, .{ id, track_id });
}

/// Блокирует дефолтный плейлист пользователя и возвращает его ID; иначе NotFound.
pub fn lockDefault(conn: *database.Connection, arena: std.mem.Allocator, user: []const u8) ![]const u8 {
    const query = "SELECT id::text FROM musica.playlists WHERE owner_id = $1 AND is_default FOR UPDATE";

    return (try conn.queryText(arena, query, .{user})) orelse error.NotFound;
}

/// Удаляет только привязку трека к плейлисту; иначе TrackNotFound.
pub fn removeTrack(conn: *database.Connection, id: []const u8, track_id: []const u8) !void {
    const query = "DELETE FROM musica.track_playlists WHERE playlist_id = $1 AND track_id = $2";

    if (try conn.exec(query, .{ id, track_id }) != 1) return error.TrackNotFound;
}

/// Сохраняет ключ обложки в записи плейлиста; иначе NotFound. В S3 не обращается.
pub fn setImage(conn: *database.Connection, id: []const u8, key: []const u8) !void {
    const query = "UPDATE musica.playlists SET image_key = $2 WHERE id = $1";

    if (try conn.exec(query, .{ id, key }) != 1) return error.NotFound;
}

/// Удаляет привязки и обычный плейлист, возвращая ключ обложки для очистки.
/// Защиту Uploads и права проверяет вызывающий сервис; операция требует транзакции.
pub fn remove(conn: *database.Connection, arena: std.mem.Allocator, id: []const u8) !?[]const u8 {
    const unlink_query = "DELETE FROM musica.track_playlists WHERE playlist_id = $1";

    _ = try conn.exec(unlink_query, .{id});

    const remove_query =
        \\DELETE
        \\FROM musica.playlists
        \\WHERE id = $1
        \\AND NOT is_default
        \\RETURNING json_build_object('image_key', image_key)::text
    ;

    const body = (try conn.queryText(arena, remove_query, .{id})) orelse return error.NotFound;
    const files = std.json.parseFromSliceLeaky(struct { image_key: ?[]const u8 }, arena, body, .{}) catch return error.DatabaseUnavailable;
    return files.image_key;
}
