const std = @import("std");
const database = @import("../../infrastructure/database.zig");
const model = @import("model.zig");
const repository = @import("repository.zig");
const cleanup_service = @import("cleanup_service.zig");
const jobs_repository = @import("../../infrastructure/jobs/repository.zig");
const streaming_model = @import("../streaming/model.zig");
const spotify_int_model = @import("../spotify_int/model.zig");

/// Requires an open transaction; the caller owns commit and rollback.
pub fn remove(conn: *database.Connection, arena: std.mem.Allocator, user: []const u8, id: []const u8) !void {
    const key = try std.ascii.allocLowerString(arena, id);
    const location = try repository.lockForDeletion(conn, arena, user, key);
    if (try jobs_repository.find(conn, arena, spotify_int_model.download_job_kind, key, true)) |job| {
        if (try jobs_repository.isActive(conn, arena, job.id)) return error.UploadInProgress;
    }
    if (try jobs_repository.find(conn, arena, model.upload_job_kind, key, true)) |job| {
        if (try jobs_repository.isActive(conn, arena, job.id)) return error.UploadInProgress;
    }
    if (try jobs_repository.find(conn, arena, streaming_model.preparation_job_kind, key, true)) |job| {
        if (try jobs_repository.isActive(conn, arena, job.id)) return error.TrackPreparationInProgress;
    }
    _ = try cleanup_service.enqueue(conn, arena, location.bucket, &.{location.key}, 0);
    if (location.prefix) |prefix| {
        var keys: std.ArrayList([]const u8) = .empty;
        for (0..location.segments.?) |index| try keys.append(arena, try std.fmt.allocPrint(arena, "{s}/segment-{d:0>6}.ts", .{ prefix, index }));
        try keys.append(arena, try std.fmt.allocPrint(arena, "{s}/index.m3u8", .{prefix}));
        _ = try cleanup_service.enqueue(conn, arena, location.hls_bucket.?, keys.items, 0);
    }
    try jobs_repository.removeByKey(conn, streaming_model.preparation_job_kind, key);
    try jobs_repository.removeByKey(conn, model.upload_job_kind, key);
    try jobs_repository.removeByKey(conn, spotify_int_model.download_job_kind, key);
    try repository.remove(conn, key);
}
