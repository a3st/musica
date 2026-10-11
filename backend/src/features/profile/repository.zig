const impl = @import("../../infrastructure/repositories/profile.zig");

pub const read = impl.read;

pub const readCredentials = impl.readCredentials;

pub const lockCredentials = impl.lockCredentials;

pub const listOwnedTracks = impl.listOwnedTracks;

pub const listPlaylistImages = impl.listPlaylistImages;

pub const setPassword = impl.setPassword;

pub const remove = impl.remove;
