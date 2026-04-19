/// Concurrent effect propagation — fan out work across threads,
/// each inheriting the caller's effect handlers via snapshot/restore.
const std = @import("std");
const fx = @import("fx");

// ── Effects ─────────────────────────────────────────────────────────

const Logger = fx.Effect(union(enum) {
    info: fx.Op([]const u8, void),
});

const Metrics = fx.Effect(union(enum) {
    inc: fx.Op([]const u8, void),
});

// ── Business logic: parallel workers ────────────────────────────────

fn worker(snap: fx.Snapshot, id: []const u8) u64 {
    fx.restore(snap);
    Logger.exec(.info, id);
    Metrics.exec(.inc, "tasks.completed");
    return 1;
}

fn fanOut(io: std.Io, tasks: []const []const u8) u64 {
    const snap = fx.snapshot();

    var futures: [8]std.Io.Future(u64) = undefined;
    const n = @min(tasks.len, futures.len);

    for (tasks[0..n], futures[0..n]) |id, *f| {
        f.* = io.concurrent(worker, .{ snap, id }) catch {
            Logger.exec(.info, "spawn failed");
            continue;
        };
    }

    var total: u64 = 0;
    for (futures[0..n]) |*f| {
        total += f.await(io);
    }
    return total;
}

// ── Handlers ────────────────────────────────────────────────────────

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

// ── Main ────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    var log = StderrLogger{};
    var met = AtomicCounter{};
    fx.init(.{
        .{ Logger, &log },
        .{ Metrics, &met },
    });

    const tasks = [_][]const u8{ "fetch-users", "fetch-orders", "fetch-inventory", "build-report" };

    Logger.exec(.info, "dispatching work");
    const completed = fanOut(init.io, &tasks);

    std.debug.print("\ncompleted: {d}, metrics count: {d}\n", .{
        completed,
        met.count.load(.acquire),
    });
}

// ── Tests: deterministic without threads ────────────────────────────

const TestLogger = struct {
    buf: [64][]const u8 = undefined,
    len: usize = 0,

    pub fn info(self: *TestLogger, msg: []const u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = msg;
            self.len += 1;
        }
    }
};

const TestCounter = struct {
    count: u64 = 0,
    pub fn inc(self: *TestCounter, _: []const u8) void {
        self.count += 1;
    }
};

test "worker uses restored effects" {
    var log = TestLogger{};
    var met = TestCounter{};
    fx.init(.{
        .{ Logger, &log },
        .{ Metrics, &met },
    });

    const snap = fx.snapshot();
    _ = worker(snap, "test-task");

    try std.testing.expectEqual(@as(usize, 1), log.len);
    try std.testing.expectEqualStrings("test-task", log.buf[0]);
    try std.testing.expectEqual(@as(u64, 1), met.count);
}
