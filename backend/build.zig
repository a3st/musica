const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Run only tests whose names contain this text");
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
    const exe = b.addExecutable(.{ .name = "musica-backend", .root_module = module });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the API server").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = module, .filters = if (test_filter) |filter| &.{filter} else &.{} });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run backend unit tests").dependOn(&run_tests.step);

    const download_fixture = b.addExecutable(.{
        .name = "yt-dlp-fixture",
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/fixtures/yt_dlp.zig"), .target = target, .optimize = optimize, .link_libc = true }),
    });
    const install_fixture = b.addInstallArtifact(download_fixture, .{});
    b.step("test-download-fixture", "Build offline download fixture for API integration checks").dependOn(&install_fixture.step);
}
