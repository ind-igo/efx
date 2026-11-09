const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const efx_mod = b.addModule("efx", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests — core
    const test_step = b.step("test", "Run tests");
    const core_tests = b.addTest(.{ .root_module = efx_mod });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    // Examples — each is a standalone executable with its own tests
    const examples = [_][]const u8{ "logger", "clock", "dst", "storage", "concurrent", "tracing", "generator", "batch" };

    for (examples) |name| {
        const example_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "efx", .module = efx_mod }},
        });

        const exe = b.addExecutable(.{ .name = name, .root_module = example_mod });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the {s} example", .{name})).dependOn(&run.step);

        const example_tests = b.addTest(.{ .root_module = example_mod });
        test_step.dependOn(&b.addRunArtifact(example_tests).step);
    }

    // Missing-handler panics, in every build mode. They end the process, so
    // they are checked from outside it.
    for (std.enums.values(std.builtin.OptimizeMode)) |mode| {
        const mod = b.createModule(.{
            .root_source_file = b.path("tests/unbound_panic.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{.{ .name = "efx", .module = efx_mod }},
        });
        const exe = b.addExecutable(.{ .name = "unbound-panic", .root_module = mod });
        for ([_][]const u8{ "never", "elsewhere" }, [_][]const u8{
            "efx: effect was never bound in any scope: unbound_panic.NeverBound",
            "efx: no handler bound in this scope for unbound_panic.BoundElsewhere",
        }) |case, message| {
            const run = b.addRunArtifact(exe);
            run.addArg(case);
            run.expectStdErrMatch(message);
            run.addCheck(.{ .expect_term = .{ .signal = .ABRT } });
            test_step.dependOn(&run.step);
        }
    }

    // Misuse of a Contract must not compile. See tests/compile_fail.zig.
    for ([_]struct { []const u8, []const u8 }{
        .{ "exec_unlisted", "is not listed in Contract(compile_fail.Clock)" },
        .{ "from_missing", "compile_fail.Log is missing from the source" },
        .{ "init_missing", "has no handler for compile_fail.Log" },
        .{ "bind_unlisted", "cannot bind compile_fail.Log" },
        .{ "from_plain_scope", "a plain Scope, which has no list" },
        .{ "handler_uses_unlisted_init", "LoggingClock handles compile_fail.Clock and uses compile_fail.Log, which is not listed in Contract(compile_fail.Clock)" },
        .{ "handler_uses_unlisted_bind", "LoggingClock handles compile_fail.Clock and uses compile_fail.Log" },
        .{ "handler_wrong_scope_param", "sc must be a *const efx.Scope or a *const Contract" },
        .{ "exec_by_value", "by pointer (&sc)" },
    }) |case| {
        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "test", "--dep", "efx" });
        run.addPrefixedFileArg("-Mroot=", b.path("tests/compile_fail.zig"));
        run.addPrefixedFileArg("-Mefx=", b.path("src/root.zig"));
        run.addArgs(&.{ "--test-filter", case[0] });
        run.has_side_effects = true;
        run.expectStdErrMatch(case[1]);
        run.expectExitCode(1);
        test_step.dependOn(&run.step);
    }

    // Benchmarks: `zig build bench` runs one quick pass as raw CSV.
    // bench/run.sh collects the numbers in the README.
    const bench_step = b.step("bench", "Run a quick benchmark pass");
    for ([_]bool{ false, true }) |omit_frame_pointer| {
        const mod = b.createModule(.{
            .root_source_file = b.path("bench/dispatch.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .omit_frame_pointer = omit_frame_pointer,
            .imports = &.{.{ .name = "efx", .module = efx_mod }},
        });
        const name = if (omit_frame_pointer) "bench-dispatch-nofp" else "bench-dispatch";
        const exe = b.addExecutable(.{ .name = name, .root_module = mod });
        b.installArtifact(exe);
        if (!omit_frame_pointer) {
            const run = b.addRunArtifact(exe);
            run.addArgs(&.{ "shuf", "1", "mono", "1" });
            bench_step.dependOn(&run.step);
        }
    }
}
