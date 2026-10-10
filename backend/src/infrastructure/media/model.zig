/// Метаданные ffprobe; artwork_stream указывает только встроенную картинку, а не видеодорожку.
pub const Metadata = struct {
    duration_seconds: ?u32,
    artwork_stream: ?u32,
};
