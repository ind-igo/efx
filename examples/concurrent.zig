/// Concurrent effect propagation — fan out work across threads,
/// each inheriting the caller's effect handlers via the Scope value.
const std = @import("std");
const efx = @import("efx");

// ── Effects ─────────────────────────────────────────────────────────

const Logger = efx.Effect(union(enum) {
    info: efx.Op([]const u8, void),
});

const Metrics = efx.Effect(union(enum) {
    inc: efx.Op([]const u8, void),
});

// ── Business logic: parallel workers ────────────────────────────────

fn worker(sc: *const efx.Scope, id: []const u8) u64 {
    Logger.exec(sc, .info, id);
    Metrics.exec(sc, .inc, "tasks.completed");
    return 1;
}

fn fanOut(io: std.Io, sc: *const efx.Scope, tasks: []const []const u8) u64 {
    var futures: [8]std.Io.Future(u64) = undefined;
    const n = @min(tasks.len, futures.len);
    var spawned: usize = 0;

    for (tasks[0..n]) |id| {
        futures[spawned] = io.concurrent(worker, .{ sc, id }) catch {
            Logger.exec(sc, .info, "spawn failed");
            continue;
        };
        spawned += 1;
    }

    var total: u64 = 0;
    for (futures[0..spawned]) |*f| {
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
    const sc = efx.Scope.init(.{
        .{ Logger, &log },
        .{ Metrics, &met },
    });

    const tasks = [_][]const u8{ "fetch-users", "fetch-orders", "fetch-inventory", "build-report" };

    Logger.exec(&sc, .info, "dispatching work");
    const completed = fanOut(init.io, &sc, &tasks);

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

test "worker uses effects from scope" {
    var log = TestLogger{};
    var met = TestCounter{};
    const sc = efx.Scope.init(.{
        .{ Logger, &log },
        .{ Metrics, &met },
    });

    _ = worker(&sc, "test-task");

    try std.testing.expectEqual(@as(usize, 1), log.len);
    try std.testing.expectEqualStrings("test-task", log.buf[0]);
    try std.testing.expectEqual(@as(u64, 1), met.count);
}
