/// Deterministic Simulation Testing (DST) example.
///
/// Demonstrates: same seed → same behavior, event tracing for debugging,
/// and fault injection — all via effect handlers, zero changes to business logic.
const std = @import("std");
const fx = @import("fx");

// ── Effects (reused from clock.zig / random.zig) ────────────────────

pub const Clock = fx.Effect(union(enum) {
    timestamp_ms: fx.Op(void, i64),
    sleep_ms: fx.Op(u64, void),
});

pub const Range = struct { min: u64, max: u64 };

pub const Random = fx.Effect(union(enum) {
    int_u64: fx.Op(void, u64),
    range: fx.Op(Range, u64),
    boolean: fx.Op(void, bool),
});

// ── Event trace ─────────────────────────────────────────────────────

pub const Event = union(enum) {
    timestamp_ms: i64,
    sleep_ms: u64,
    int_u64: u64,
    range: struct { min: u64, max: u64, result: u64 },
    boolean: bool,
};

pub const TraceEntry = struct {
    time_ms: i64,
    event: Event,
};

// ── Simulator ───────────────────────────────────────────────────────

pub const Simulator = struct {
    rng: std.Random.DefaultPrng,
    now_ms: i64 = 0,
    trace: std.ArrayList(TraceEntry),
    allocator: std.mem.Allocator,

    pub fn init(seed: u64, allocator: std.mem.Allocator) Simulator {
        return .{
            .rng = std.Random.DefaultPrng.init(seed),
            .now_ms = 0,
            .trace = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Simulator) void {
        self.trace.deinit(self.allocator);
    }

    fn record(self: *Simulator, event: Event) void {
        self.trace.append(self.allocator, .{ .time_ms = self.now_ms, .event = event }) catch {};
    }

    pub fn dump(self: *const Simulator) void {
        std.debug.print("── trace ({d} events) ──\n", .{self.trace.items.len});
        for (self.trace.items) |entry| {
            std.debug.print("  [t={d}ms] ", .{entry.time_ms});
            switch (entry.event) {
                .timestamp_ms => |v| std.debug.print("clock.timestamp_ms -> {d}\n", .{v}),
                .sleep_ms => |v| std.debug.print("clock.sleep_ms({d})\n", .{v}),
                .int_u64 => |v| std.debug.print("random.int_u64 -> {d}\n", .{v}),
                .range => |r| std.debug.print("random.range({d}..{d}) -> {d}\n", .{ r.min, r.max, r.result }),
                .boolean => |v| std.debug.print("random.boolean -> {}\n", .{v}),
            }
        }
        std.debug.print("── end trace ──\n", .{});
    }

    pub fn timestamp_ms(self: *Simulator) i64 {
        self.record(.{ .timestamp_ms = self.now_ms });
        return self.now_ms;
    }

    pub fn sleep_ms(self: *Simulator, ms: u64) void {
        self.record(.{ .sleep_ms = ms });
        self.now_ms += @intCast(ms);
    }

    pub fn int_u64(self: *Simulator) u64 {
        const v = self.rng.random().int(u64);
        self.record(.{ .int_u64 = v });
        return v;
    }

    pub fn range(self: *Simulator, r: Range) u64 {
        const v = self.rng.random().intRangeAtMost(u64, r.min, r.max);
        self.record(.{ .range = .{ .min = r.min, .max = r.max, .result = v } });
        return v;
    }

    pub fn boolean(self: *Simulator) bool {
        const v = self.rng.random().boolean();
        self.record(.{ .boolean = v });
        return v;
    }
};

// ── Business logic: retry with random jitter ────────────────────────

pub const RetryResult = struct {
    succeeded: bool,
    attempts: u32,
    elapsed_ms: i64,
};

fn retryWithJitter(sc: *const fx.Scope, max_attempts: u32, base_delay_ms: u64) RetryResult {
    const start = Clock.exec(sc, .timestamp_ms, {});
    var attempt: u32 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        if (Random.exec(sc, .boolean, {})) {
            return .{
                .succeeded = true,
                .attempts = attempt + 1,
                .elapsed_ms = Clock.exec(sc, .timestamp_ms, {}) - start,
            };
        }
        const jitter = Random.exec(sc, .range, .{ .min = 0, .max = base_delay_ms });
        Clock.exec(sc, .sleep_ms, base_delay_ms + jitter);
    }
    return .{
        .succeeded = false,
        .attempts = max_attempts,
        .elapsed_ms = Clock.exec(sc, .timestamp_ms, {}) - start,
    };
}

// ── Helpers ─────────────────────────────────────────────────────────

fn runSim(seed: u64, allocator: std.mem.Allocator) struct { result: RetryResult, sim: Simulator } {
    var sim = Simulator.init(seed, allocator);
    const sc = fx.Scope.init(.{
        .{ Clock, &sim },
        .{ Random, &sim },
    });
    const result = retryWithJitter(&sc, 5, 200);
    return .{ .result = result, .sim = sim };
}

// ── Tests ───────────────────────────────────────────────────────────

test "same seed → identical results" {
    var run1 = runSim(42, std.testing.allocator);
    defer run1.sim.deinit();
    var run2 = runSim(42, std.testing.allocator);
    defer run2.sim.deinit();

    try std.testing.expectEqual(run1.result.succeeded, run2.result.succeeded);
    try std.testing.expectEqual(run1.result.attempts, run2.result.attempts);
    try std.testing.expectEqual(run1.result.elapsed_ms, run2.result.elapsed_ms);
    try std.testing.expectEqual(run1.sim.trace.items.len, run2.sim.trace.items.len);
}

test "different seeds diverge" {
    var run1 = runSim(42, std.testing.allocator);
    defer run1.sim.deinit();
    var run2 = runSim(123, std.testing.allocator);
    defer run2.sim.deinit();

    const diverged = run1.result.attempts != run2.result.attempts or
        run1.result.elapsed_ms != run2.result.elapsed_ms;
    try std.testing.expect(diverged);
}

test "trace captures every effect call" {
    var run = runSim(42, std.testing.allocator);
    defer run.sim.deinit();
    try std.testing.expect(run.sim.trace.items.len > 0);
}

test "fault injection: always-fail operation exhausts retries" {
    var sim = Simulator.init(0, std.testing.allocator);
    defer sim.deinit();
    var fail_rng = AlwaysFailRandom{};

    const sc = fx.Scope.init(.{
        .{ Clock, &sim },
        .{ Random, &fail_rng },
    });

    const result = retryWithJitter(&sc, 3, 100);

    try std.testing.expect(!result.succeeded);
    try std.testing.expectEqual(@as(u32, 3), result.attempts);
    try std.testing.expectEqual(@as(i64, 300), result.elapsed_ms);
}

const AlwaysFailRandom = struct {
    pub fn int_u64(_: *AlwaysFailRandom) u64 { return 0; }
    pub fn range(_: *AlwaysFailRandom, r: Range) u64 { return r.min; }
    pub fn boolean(_: *AlwaysFailRandom) bool { return false; }
};

// ── Main: run a few seeds, print results ────────────────────────────

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const seeds = [_]u64{ 42, 123, 999, 7, 31415 };

    for (seeds) |seed| {
        var sim = Simulator.init(seed, allocator);
        defer sim.deinit();

        const sc = fx.Scope.init(.{
            .{ Clock, &sim },
            .{ Random, &sim },
        });

        const result = retryWithJitter(&sc, 5, 200);
        std.debug.print("seed={d:<6} succeeded={} attempts={d} elapsed={d}ms\n", .{
            seed, result.succeeded, result.attempts, result.elapsed_ms,
        });
        sim.dump();
    }
}
