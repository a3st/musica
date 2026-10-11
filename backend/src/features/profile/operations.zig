const std = @import("std");
const database = @import("../../infrastructure/database.zig");
const repository = @import("repository.zig");
const tracks_operations = @import("../tracks/operations.zig");
const tracks_cleanup_service = @import("../tracks/cleanup_service.zig");

/// Удаляет данные заблокированной обычной учётки в транзакции вызывающего сервиса.
/// Проверку полномочий выполняет вызывающий сервис; активный трек отменяет операцию.
pub fn removeAccount(conn: *database.Connection, arena: std.mem.Allocator, user: []const u8, bucket: []const u8) !void {
    const images = try repository.listPlaylistImages(conn, arena, user);

    for (try repository.listOwnedTracks(conn, arena, user)) |id| {
        try tracks_operations.remove(conn, arena, user, id);
    }
    for (images) |key| {
        _ = try tracks_cleanup_service.enqueue(conn, arena, bucket, &.{key}, 0);
    }

    try repository.remove(conn, user);
}
