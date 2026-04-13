const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libfx = b.addModule("fx", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests — core
    const test_step = b.step("test", "Run tests");
    const core_tests = b.addTest(.{ .root_module = libfx });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    // Examples — each is a standalone executable with its own tests
    const examples = [_][]const u8{ "logger", "clock", "random", "dst", "pipeline" };

    for (examples) |name| {
        const example_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fx", .module = libfx }},
        });

        const exe = b.addExecutable(.{ .name = name, .root_module = example_mod });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the {s} example", .{name})).dependOn(&run.step);

        const example_tests = b.addTest(.{ .root_module = example_mod });
        test_step.dependOn(&b.addRunArtifact(example_tests).step);
    }

    // Benchmarks
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/dispatch.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "fx", .module = libfx }},
    });
    const bench_exe = b.addExecutable(.{ .name = "bench-dispatch", .root_module = bench_mod });
    b.installArtifact(bench_exe);
    const bench_run = b.addRunArtifact(bench_exe);
    b.step("bench", "Run dispatch benchmark").dependOn(&bench_run.step);
}
