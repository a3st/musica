/// Тело удаления собственного аккаунта; текущий пароль подтверждает право на операцию.
pub const Confirmation = struct {
    password: []const u8,
};

/// Текущий пароль и новый пароль длиной 12–1024 байта.
pub const ChangePassword = struct {
    password: []const u8,
    new_password: []const u8,
};
