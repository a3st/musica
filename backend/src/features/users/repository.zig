const impl = @import("../../infrastructure/repositories/users.zig");

pub const ensureSystem = impl.ensureSystem;

pub const requireAdmin = impl.requireAdmin;

pub const bootstrapAdmin = impl.bootstrapAdmin;
