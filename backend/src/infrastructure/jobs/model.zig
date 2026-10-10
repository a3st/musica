const std = @import("std");

/// Состояние задачи в общей очереди; переходами управляет репозиторий jobs.
pub const State = enum {
    /// Ожидает выполнения после available_at.
    queued,
    /// Выполняется в рамках попытки с ограниченной арендой.
    processing,
    /// Успешно завершена.
    completed,
    /// Завершена с ошибкой; автоматический повтор не запланирован.
    failed,
};

/// Произвольные JSON-данные задачи; схему и проверку определяет соответствующая фича.
pub const Payload = std.json.Value;

/// Общая запись public.jobs без полей конкретных фич.
/// Строки и payload прочитанной записи живут до освобождения arena вызывающего кода.
/// Временные метки представлены миллисекундами Unix в UTC и формируются по часам БД.
pub const Job = struct {
    /// UUID задачи.
    id: []const u8,
    /// Вид задачи, определяющий обработчик и схему payload.
    kind: []const u8,
    /// Ключ дедупликации внутри kind; null позволяет создавать независимые задачи.
    dedupe_key: ?[]const u8,
    state: State,

    /// UUID попытки; вместе с действующей арендой защищает от обновлений устаревшим обработчиком.
    attempt_id: ?[]const u8,
    /// Число начатых попыток; увеличивается при получении аренды.
    attempts: u32,
    /// Лимит попыток для повтора после ошибки; null означает отсутствие лимита.
    max_attempts: ?u32,
    /// Срок действия аренды; null, если действующая аренда отсутствует.
    lease_until: ?i64,

    /// Самый ранний момент, когда queued-задача доступна для выполнения.
    available_at: i64,
    /// Время создания записи.
    created_at: i64,
    /// Время последнего изменения записи.
    updated_at: i64,

    /// Данные конкретной задачи; для типизированного доступа используйте decodePayload.
    payload: Payload,

    /// Преобразует payload в T, проверяя JSON-типы и обязательные поля.
    /// Ошибки разбора переводит в InvalidJobPayload; выделенные данные живут до освобождения arena.
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
