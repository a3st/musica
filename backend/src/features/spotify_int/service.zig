const std = @import("std");
const App = @import("../../app.zig").App;
const database = @import("../../infrastructure/database.zig");
const model = @import("model.zig");
const imports_service = @import("../imports/service.zig");
const playlists_repository = @import("../playlists/repository.zig");

/// Проверяет импорт и атомарно создаёт пользовательские плейлисты, привязки общих треков и задачи загрузки.
/// Дедуплицирует записи внутри импорта; результат в arena не означает завершение скачивания.
pub fn create(app: *App, arena: std.mem.Allocator, user: []const u8, input: model.Import) !model.Result {
    try imports_service.requireEnabled(app);

    try model.validateImport(input);

    const conn = try app.db.acquire();
    defer conn.release();

    try conn.begin();
    errdefer conn.rollback() catch {};

    var tracks: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer tracks.deinit(arena);

    const playlists = try arena.alloc([]const u8, input.playlists.len);
    for (input.playlists, 0..) |playlist, index| {
        playlists[index] = try playlists_repository.create(
            conn,
            arena,
            user,
            std.mem.trim(u8, playlist.title, " \t\r\n"),
            playlist.description,
            "[]",
            "private",
        );
        for (playlist.tracks) |track| {
            const track_id = try createTrack(app, conn, arena, user, track, &tracks);
            try playlists_repository.addTrack(conn, arena, playlists[index], user, track_id);
        }
    }
    for (input.library) |track| _ = try createTrack(app, conn, arena, user, track, &tracks);

    var unique: std.StringHashMapUnmanaged(void) = .empty;
    defer unique.deinit(arena);

    var ids = tracks.valueIterator();
    while (ids.next()) |track_id| try unique.put(arena, track_id.*, {});

    try conn.commit();

    return .{ .tracks = unique.count(), .playlists = playlists };
}

/// Переиспользует трек внутри импорта или готовит скачивание и добавляет общий трек в Uploads.
/// Принимает соединение с транзакцией вызывающего кода; результат хранится в arena.
fn createTrack(
    app: *App,
    conn: *database.Connection,
    arena: std.mem.Allocator,
    user: []const u8,
    track: model.Track,
    tracks: *std.StringHashMapUnmanaged([]const u8),
) ![]const u8 {
    const entry = try tracks.getOrPut(arena, try model.importDeduplicationKey(arena, track));
    if (entry.found_existing) return entry.value_ptr.*;

    const uploads = try playlists_repository.lockDefault(conn, arena, user);
    const id = try imports_service.enqueueTrack(
        app,
        conn,
        arena,
        .{ .title = track.title, .artist = track.artist },
        if (track.spotify_uri) |uri| .{ .provider = "spotify", .external_id = uri[14..] } else null,
    );
    try playlists_repository.addTrack(conn, arena, uploads, user, id);

    entry.value_ptr.* = id;

    return id;
}
