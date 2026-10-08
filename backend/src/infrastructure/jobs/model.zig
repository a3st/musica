const std = @import("std");

pub const State = enum { queued, processing, completed, failed };
pub const Payload = std.json.Value;

pub const Job = struct {
    id: []const u8,
    kind: []const u8,
    dedupe_key: ?[]const u8,
    state: State,
    attempt_id: ?[]const u8,
    attempts: u32,
    max_attempts: ?u32,
    lease_until: ?i64,
    available_at: i64,
    created_at: i64,
    updated_at: i64,
    payload: Payload,

    // Timestamps are UTC milliseconds since Unix epoch. Memory belongs to the caller's arena.
    pub fn decodePayload(self: Job, comptime T: type, arena: std.mem.Allocator) !T {
        return std.json.parseFromValueLeaky(T, arena, self.payload, .{}) catch error.InvalidJobPayload;
    }
};

test "job payload decoding checks runtime JSON types and required fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const T = struct { count: u32 };
    const value = try std.json.parseFromSliceLeaky(Payload, arena.allocator(), "{\"count\":2}", .{});
    const job: Job = .{ .id = "id", .kind = "custom", .dedupe_key = null, .state = .queued, .attempt_id = null, .attempts = 0, .max_attempts = null, .lease_until = null, .available_at = 0, .created_at = 0, .updated_at = 0, .payload = value };
    try std.testing.expectEqual(@as(u32, 2), (try job.decodePayload(T, arena.allocator())).count);
    try std.testing.expectError(error.InvalidJobPayload, job.decodePayload(struct { missing: bool }, arena.allocator()));
    try std.testing.expectError(error.InvalidJobPayload, job.decodePayload(struct { count: bool }, arena.allocator()));
}
