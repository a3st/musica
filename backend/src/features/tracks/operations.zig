const std = @import("std");
const database = @import("../../infrastructure/database.zig");
const model = @import("model.zig");
const repository = @import("repository.zig");
const cleanup_service = @import("cleanup_service.zig");
const jobs_repository = @import("../../infrastructure/jobs/repository.zig");
const streaming_model = @import("../streaming/model.zig");
const imports_model = @import("../imports/model.zig");
const playlists_repository = @import("../playlists/repository.zig");

/// Удаляет личный трек целиком или отвязывает общий трек сервисной учётки от Uploads пользователя.
/// Требует открытой транзакции; доступ к Uploads и наличие привязки проверяет вызывающий сервис.
pub fn removeFromLibrary(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    user: []const u8,
    id: []const u8,
    playlist: []const u8,
) !void {
    const owner = try repository.lockOwner(conn, arena, id);
    if (std.mem.eql(u8, owner.id, user)) return remove(conn, arena, user, id);
    if (!std.mem.eql(u8, owner.kind, "system")) return error.TrackNotFound;

    try playlists_repository.removeTrack(conn, playlist, id);
}

/// Удаляет запись трека владельца и связанные jobs, ставя очистку исходника и HLS в очередь.
/// Требует открытой транзакции; не обращается к S3 и не завершает транзакцию.
pub fn remove(
    conn: *database.Connection,
    arena: std.mem.Allocator,
    user: []const u8,
    id: []const u8,
) !void {
    const key = try std.ascii.allocLowerString(arena, id);
    const location = try repository.lockForDeletion(conn, arena, user, key);

    if (try jobs_repository.lockByKey(conn, arena, imports_model.download_job_kind, key)) |job| {
        if (try jobs_repository.isActive(conn, arena, job.id)) return error.UploadInProgress;
    }

    if (try jobs_repository.lockByKey(conn, arena, model.upload_job_kind, key)) |job| {
        if (try jobs_repository.isActive(conn, arena, job.id)) return error.UploadInProgress;
    }

    if (try jobs_repository.lockByKey(conn, arena, streaming_model.preparation_job_kind, key)) |job| {
        if (try jobs_repository.isActive(conn, arena, job.id)) return error.TrackPreparationInProgress;
    }

    _ = try cleanup_service.enqueue(conn, arena, location.bucket, &.{location.key}, 0);

    if (location.artwork_key) |artwork_key| {
        _ = try cleanup_service.enqueue(conn, arena, location.bucket, &.{artwork_key}, 0);
    }

    if (location.prefix) |prefix| {
        var keys: std.ArrayList([]const u8) = .empty;

        for (0..location.segments.?) |index| try keys.append(
            arena,
            try std.fmt.allocPrint(arena, "{s}/segment-{d:0>6}.ts", .{ prefix, index }),
        );

        try keys.append(arena, try std.fmt.allocPrint(arena, "{s}/index.m3u8", .{prefix}));

        _ = try cleanup_service.enqueue(conn, arena, location.hls_bucket.?, keys.items, 0);
    }

    try jobs_repository.removeByKey(conn, streaming_model.preparation_job_kind, key);
    try jobs_repository.removeByKey(conn, imports_model.download_job_kind, key);
    try jobs_repository.removeByKey(conn, model.upload_job_kind, key);
    try jobs_repository.removeByKey(conn, model.metadata_job_kind, key);

    try repository.remove(conn, key);
}
