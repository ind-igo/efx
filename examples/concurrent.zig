//! Sharing a scope across concurrent tasks.
//!
//! A `Scope` is immutable and has no thread affinity, so tasks can share one
//! by pointer. Its handlers are shared too: efx does no locking, so any handler
//! reachable from concurrent tasks must be thread-safe itself. See `AtomicCounter`.
const std = @import("std");
const efx = @import("efx");

// ── Effects ─────────────────────────────────────────────────────────

const Logger = efx.Effect(union(enum) {
    info: efx.Op([]const u8, void),
});

const Metrics = efx.Effect(union(enum) {
    inc: efx.Op([]const u8, void),
});

// ── Business logic: sees only the scope ─────────────────────────────

fn worker(sc: *const efx.Scope, task: []const u8) void {
    Logger.exec(sc, .info, task);
    Metrics.exec(sc, .inc, "tasks.completed");
}

// ── Spawning: stays with the code that owns `Io` ────────────────────

fn fanOut(io: std.Io, sc: *const efx.Scope, tasks: []const []const u8) !void {
    var group: std.Io.Group = .init;
    defer group.cancel(io);

    for (tasks) |task| try group.concurrent(io, worker, .{ sc, task });
    try group.await(io);
}

// ── Handlers ────────────────────────────────────────────────────────

/// Safe to share: `std.debug.print` takes a global lock.
const StderrLogger = struct {
    pub fn info(_: *StderrLogger, msg: []const u8) void {
        std.debug.print("[INFO] {s}\n", .{msg});
    }
};

const AtomicCounter = struct {
    count: std.atomic.Value(u64) = .init(0),

    pub fn inc(self: *AtomicCounter, _: []const u8) void {
        _ = self.count.fetchAdd(1, .monotonic);
    }
};

const NoopLogger = struct {
    pub fn info(_: *NoopLogger, _: []const u8) void {}
};

// ── Main ────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    var log = StderrLogger{};
    var met = AtomicCounter{};
    const sc = efx.Scope.init(.{
        .{ Logger, &log },
        .{ Metrics, &met },
    });

    const tasks = [_][]const u8{ "fetch-users", "fetch-orders", "fetch-inventory", "build-report" };
    try fanOut(init.io, &sc, &tasks);

    std.debug.print("completed: {d}\n", .{met.count.load(.monotonic)});
}

// ── Tests ───────────────────────────────────────────────────────────

test "every task runs, with no limit on how many" {
    var log = NoopLogger{};
    var met = AtomicCounter{};
    const sc = efx.Scope.init(.{
        .{ Logger, &log },
        .{ Metrics, &met },
    });

    const tasks: [32][]const u8 = @splat("task");
    try fanOut(std.testing.io, &sc, &tasks);

    try std.testing.expectEqual(@as(u64, tasks.len), met.count.load(.monotonic));
}
