//! Prototypes for directions beyond the released library. aarch64 macOS only.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const efx_mod = b.dependency("efx", .{ .target = target, .optimize = optimize }).module("efx");

    const test_step = b.step("test", "Run prototype tests");
    // Every mode: stack switching can break only once registers are allocated
    // across it, which Debug never does.
    for (std.enums.values(std.builtin.OptimizeMode)) |mode| {
        for ([_][]const u8{ "t", "dod_t" }) |name| {
            const mod = b.createModule(.{
                .root_source_file = b.path(b.fmt("continuations/{s}.zig", .{name})),
                .target = target,
                .optimize = mode,
                .imports = &.{.{ .name = "efx", .module = efx_mod }},
            });
            test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
        }
    }

    for ([_][]const u8{ "perf", "guard", "dod_perf", "dod_diag", "dod_attr", "switch" }) |name| {
        const mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("continuations/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "efx", .module = efx_mod }},
        });
        b.installArtifact(b.addExecutable(.{ .name = name, .root_module = mod }));
    }

    // The registry's efx reads `root.efx_effects`, so it is its own module.
    const registry = b.createModule(.{
        .root_source_file = b.path("registry/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    for ([_][]const u8{ "d_slots", "d_cols", "view_ok" }) |name| {
        const mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("registry/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "efx", .module = registry }},
        });
        b.installArtifact(b.addExecutable(.{ .name = b.fmt("registry-{s}", .{name}), .root_module = mod }));
    }
}
