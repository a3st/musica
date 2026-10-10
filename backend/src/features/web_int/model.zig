const Job = @import("../../infrastructure/jobs/model.zig").Job;

pub const download_job_kind = "download_track";
pub const cleanup_job_kind = "delete_unused_track";

pub const Track = struct { title: []const u8, artist: []const u8 };
pub const Payload = struct { user_id: []const u8, track_id: []const u8, track: Track };
pub const Task = struct { job: Job, payload: Payload };
pub const Source = struct { provider: []const u8, external_id: []const u8 };
