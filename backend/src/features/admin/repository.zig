const impl = @import("../../infrastructure/repositories/admin.zig");

pub const readStorage = impl.readStorage;

pub const listUsers = impl.listUsers;

pub const listCleanupCandidates = impl.listCleanupCandidates;
