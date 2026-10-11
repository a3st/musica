/// Статистика зарегистрированных исходников; размеры HLS и изображений сюда не входят.
pub const Storage = struct {
    source_bytes: u64,
    user_bytes: u64,
    system_bytes: u64,
    orphaned_bytes: u64,
    tracks: u64,
    orphaned_tracks: u64,
    pending_tracks: u64,
    hls_segments: u64,
    cleanup_jobs: u64,
};

/// Итог ограниченного пакета очистки; активные треки пропускаются.
pub const Cleanup = struct {
    removed: u32,
    skipped: u32,
};
