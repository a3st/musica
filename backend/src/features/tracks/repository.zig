const impl = @import("../../infrastructure/repositories/tracks.zig");

pub const create = impl.create;

pub const lockForDeletion = impl.lockForDeletion;

pub const remove = impl.remove;

pub const lockForUpload = impl.lockForUpload;

pub const finishUpload = impl.finishUpload;

pub const lock = impl.lock;

pub const lockOwner = impl.lockOwner;
