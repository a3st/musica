const impl = @import("../../infrastructure/repositories/web_int.zig");

pub const getOrCreateTrack = impl.getOrCreateTrack;

pub const readTrackStatus = impl.readTrackStatus;

pub const lockForCleanup = impl.lockForCleanup;

pub const listCleanupCandidates = impl.listCleanupCandidates;
