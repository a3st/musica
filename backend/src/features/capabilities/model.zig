/// Итоговые возможности сервера после проверки зависимостей интеграций при запуске.
pub const Capabilities = struct {
    web_search: bool,
    spotify_import: bool,
    /// Разрешает самостоятельную регистрацию; административное создание учёток независимо.
    registration_enabled: bool,
};
