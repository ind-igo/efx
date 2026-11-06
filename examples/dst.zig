//! Deterministic simulation testing.
//!
//! Retry logic talks to an upstream service, a clock and a random source. In
//! simulation one struct handles all three from a single seed, so every failure
//! and delay is reproducible: a failing seed is a bug report you can replay.
const std = @import("std");
const efx = @import("efx");

// ── Effects ─────────────────────────────────────────────────────────

const Upstream = efx.Effect(union(enum) {
    call: efx.Op(void, error{Unavailable}!void),
});

const Clock = efx.Effect(union(enum) {
    now_ms: efx.Op(void, i64),
    sleep_ms: efx.Op(u64, void),
});

const Random = efx.Effect(union(enum) {
    at_most: efx.Op(u64, u64),
});

// ── Business logic ──────────────────────────────────────────────────

const RetryResult = struct {
    succeeded: bool,
    attempts: u32,
    elapsed_ms: i64,
};

fn callWithRetry(sc: *const efx.Scope, max_attempts: u32, base_delay_ms: u64) RetryResult {
    const start = Clock.exec(sc, .now_ms, {});
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        const succeeded = if (Upstream.exec(sc, .call, {})) true else |_| false;
        if (succeeded or attempt == max_attempts) {
            return .{
                .succeeded = succeeded,
                .attempts = attempt,
                .elapsed_ms = Clock.exec(sc, .now_ms, {}) - start,
            };
        }
        Clock.exec(sc, .sleep_ms, base_delay_ms + Random.exec(sc, .at_most, base_delay_ms));
    }
}

// ── Simulator ───────────────────────────────────────────────────────

const Event = union(enum) {
    now_ms,
    sleep_ms: u64,
    at_most: u64,
    call: bool,
};

const TraceEntry = struct {
    time_ms: i64,
    event: Event,
};

/// Handles all three effects, so they share one seed and one trace.
const Simulator = struct {
    rng: std.Random.DefaultPrng,
    failure_percent: u8 = 60,
    now: i64 = 0,
    trace: [64]TraceEntry = undefined,
    trace_len: usize = 0,

    fn init(seed: u64) Simulator {
        return .{ .rng = .init(seed) };
    }

    fn events(self: *const Simulator) []const TraceEntry {
        return self.trace[0..self.trace_len];
    }

    fn record(self: *Simulator, event: Event) void {
        self.trace[self.trace_len] = .{ .time_ms = self.now, .event = event };
        self.trace_len += 1;
    }

    pub fn call(self: *Simulator) error{Unavailable}!void {
        const up = self.rng.random().uintLessThan(u8, 100) >= self.failure_percent;
        self.record(.{ .call = up });
        if (!up) return error.Unavailable;
    }

    pub fn now_ms(self: *Simulator) i64 {
        self.record(.now_ms);
        return self.now;
    }

    pub fn sleep_ms(self: *Simulator, ms: u64) void {
        self.record(.{ .sleep_ms = ms });
        self.now += @intCast(ms);
    }

    pub fn at_most(self: *Simulator, max: u64) u64 {
        const value = self.rng.random().intRangeAtMost(u64, 0, max);
        self.record(.{ .at_most = value });
        return value;
    }

    fn scope(self: *Simulator) efx.Scope {
        return .init(.{ .{ Upstream, self }, .{ Clock, self }, .{ Random, self } });
    }
};

const Outage = struct {
    pub fn call(_: *Outage) error{Unavailable}!void {
        return error.Unavailable;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const sim_attempts = 5;
const sim_delay_ms = 200;

test "same seed replays the exact trace" {
    var first = Simulator.init(42);
    var second = Simulator.init(42);
    const first_scope = first.scope();
    const second_scope = second.scope();

    const a = callWithRetry(&first_scope, sim_attempts, sim_delay_ms);
    const b = callWithRetry(&second_scope, sim_attempts, sim_delay_ms);

    try std.testing.expectEqual(a, b);
    try std.testing.expectEqualSlices(TraceEntry, first.events(), second.events());
}

test "retry bounds hold across many seeds" {
    var failures: u32 = 0;
    for (0..1000) |seed| {
        var sim = Simulator.init(seed);
        const sc = sim.scope();
        const result = callWithRetry(&sc, sim_attempts, sim_delay_ms);

        const sleeps: i64 = result.attempts - 1;
        try std.testing.expect(result.attempts >= 1 and result.attempts <= sim_attempts);
        try std.testing.expect(result.elapsed_ms >= sleeps * sim_delay_ms);
        try std.testing.expect(result.elapsed_ms <= sleeps * 2 * sim_delay_ms);
        if (!result.succeeded) failures += 1;
    }
    // Both outcomes must occur, or the sweep isn't exercising the retry path.
    try std.testing.expect(failures > 0 and failures < 1000);
}

test "fault injection: a full outage exhausts retries without a trailing sleep" {
    var sim = Simulator.init(7);
    var outage = Outage{};
    const base = sim.scope();
    const sc = base.bind(Upstream, &outage);

    const result = callWithRetry(&sc, 3, 100);

    try std.testing.expect(!result.succeeded);
    try std.testing.expectEqual(@as(u32, 3), result.attempts);
    try std.testing.expect(result.elapsed_ms >= 200 and result.elapsed_ms <= 400);
}

// ── Main: run a few seeds, print each trace ─────────────────────────

pub fn main(_: std.process.Init) !void {
    for ([_]u64{ 42, 123, 999, 7, 31415 }) |seed| {
        var sim = Simulator.init(seed);
        const sc = sim.scope();
        const result = callWithRetry(&sc, sim_attempts, sim_delay_ms);

        std.debug.print("seed={d} succeeded={} attempts={d} elapsed={d}ms\n", .{
            seed, result.succeeded, result.attempts, result.elapsed_ms,
        });
        for (sim.events()) |entry| {
            std.debug.print("  t={d}ms {any}\n", .{ entry.time_ms, entry.event });
        }
    }
}
