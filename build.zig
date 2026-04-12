const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("libfx", .{
        .root_source_file = b.path("src/libfx.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // Examples
    const examples = [_][]const u8{ "logger", "clock", "random" };

    for (examples) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "libfx", .module = mod }},
            }),
        });
        b.installArtifact(exe);

        // zig build run-<name>
        const run = b.addRunArtifact(exe);
        const run_step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the {s} example", .{name}));
        run_step.dependOn(&run.step);

        // Example tests included in `zig build test`
        const example_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "libfx", .module = mod }},
            }),
        });
        test_step.dependOn(&b.addRunArtifact(example_tests).step);
    }
}
