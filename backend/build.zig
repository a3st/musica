const std = @import("std");

/// Регистрирует сборку backend, запуск, тесты и артефакты ARM64 и x86-64 для Linux и Windows.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Run only tests whose names contain this text");

    const backend = addBackendBuildStep(b, target, optimize, null, null);

    addRunStep(b, backend);
    addTestStep(b, backend.root_module, test_filter);
    addDownloadFixtureStep(b, target, optimize);
    addLinuxBuildStep(b, optimize, .aarch64, "arm64");
    addLinuxBuildStep(b, optimize, .x86_64, "x86-64");
    addWindowsBuildStep(b, optimize, .aarch64, "arm64");
    addWindowsBuildStep(b, optimize, .x86_64, "x86-64");
}

/// Создаёт backend и подключает зависимости с той же платформой и режимом оптимизации.
fn createBackendExecutable(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const httpz = b.dependency("httpz", .{ .target = target, .optimize = optimize });
    const pg = b.dependency("pg", .{ .target = target, .optimize = optimize });

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "httpz", .module = httpz.module("httpz") },
            .{ .name = "pg", .module = pg.module("pg") },
        },
    });

    return b.addExecutable(.{
        .name = "musica-backend",
        .root_module = module,
    });
}

/// Регистрирует запуск backend и передаёт аргументы после -- исполняемому файлу.
fn addRunStep(b: *std.Build, backend: *std.Build.Step.Compile) void {
    const run = b.addRunArtifact(backend);
    if (b.args) |args| run.addArgs(args);

    b.step("run", "Run the API server").dependOn(&run.step);
}

/// Запускает unit-тесты модуля backend, при необходимости ограниченные фильтром имени.
fn addTestStep(b: *std.Build, module: *std.Build.Module, test_filter: ?[]const u8) void {
    const tests = b.addTest(.{
        .root_module = module,
        .filters = if (test_filter) |filter| &.{filter} else &.{},
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run backend unit tests").dependOn(&run_tests.step);
}

/// Собирает локальную заглушку yt-dlp для интеграционных тестов без скачивания аудио.
fn addDownloadFixtureStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const download_fixture = b.addExecutable(.{
        .name = "yt-dlp-fixture",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures/yt_dlp.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const install_fixture = b.addInstallArtifact(download_fixture, .{});
    b.step("test-download-fixture", "Build offline download fixture for API integration checks").dependOn(&install_fixture.step);
}

/// Регистрирует сборку выбранной архитектуры Linux с glibc 2.36 в отдельный каталог.
fn addLinuxBuildStep(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    architecture: std.Target.Cpu.Arch,
    architecture_name: []const u8,
) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = architecture,
        .os_tag = .linux,
        .abi = .gnu,
        .glibc_version = .{ .major = 2, .minor = 36, .patch = 0 },
    });
    const step_name = b.fmt("build-{s}", .{architecture_name});
    const install_directory = b.fmt("{s}/bin", .{architecture_name});
    _ = addBackendBuildStep(b, target, optimize, step_name, install_directory);
}

/// Регистрирует сборку выбранной архитектуры Windows с GNU ABI в отдельный каталог.
fn addWindowsBuildStep(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    architecture: std.Target.Cpu.Arch,
    architecture_name: []const u8,
) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = architecture,
        .os_tag = .windows,
        .abi = .gnu,
    });
    const step_name = b.fmt("build-windows-{s}", .{architecture_name});
    const install_directory = b.fmt("windows/{s}/bin", .{architecture_name});
    _ = addBackendBuildStep(b, target, optimize, step_name, install_directory);
}

/// Общая сборка и установка для выбранной платформы; без имени подключается к zig build.
/// Без отдельного каталога устанавливает бинарник в стандартный bin под --prefix.
fn addBackendBuildStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    step_name: ?[]const u8,
    install_directory: ?[]const u8,
) *std.Build.Step.Compile {
    const backend = createBackendExecutable(b, target, optimize);
    const install_backend = b.addInstallArtifact(backend, .{
        .dest_dir = if (install_directory) |directory|
            .{ .override = .{ .custom = directory } }
        else
            .default,
    });

    const description = b.fmt("Build backend for {s} {s}", .{
        @tagName(target.result.os.tag),
        @tagName(target.result.cpu.arch),
    });
    const step = if (step_name) |name| b.step(name, description) else b.getInstallStep();
    step.dependOn(&install_backend.step);

    return backend;
}
