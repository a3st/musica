const impl = @import("../../infrastructure/repositories/web_int.zig");

pub const readPlaybackTrack = impl.readPlaybackTrack;

pub const lockForCleanup = impl.lockForCleanup;

pub const listCleanupCandidates = impl.listCleanupCandidates;

pub const readSearchCache = impl.readSearchCache;

pub const writeSearchCache = impl.writeSearchCache;

pub const searchLocal = impl.searchLocal;

pub const deduplicateSearchResults = impl.deduplicateSearchResults;
