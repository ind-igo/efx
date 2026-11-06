//! Tracing through a composing handler.
//!
//! Business logic only marks where spans begin and end. The handler receives
//! the scope and calls other effects itself, so span timing comes from `Clock`
//! and durations flow to `Metrics` without the business logic touching either.
//! Tests keep the real tracer and swap what it depends on.
const std = @import("std");
const efx = @import("efx");

// ── Effects ─────────────────────────────────────────────────────────

const SpanId = enum(u32) { none = 0, _ };
const Status = enum { ok, err };

const Start = struct { name: []const u8, parent: SpanId = .none };
const End = struct { span: SpanId, status: Status };
const Sample = struct { name: []const u8, value_ms: u64 };

const Trace = efx.Effect(union(enum) {
    start: efx.Op(Start, SpanId),
    end: efx.Op(End, void),
});

const Metrics = efx.Effect(union(enum) {
    observe: efx.Op(Sample, void),
});

const Clock = efx.Effect(union(enum) {
    now_ms: efx.Op(void, i64),
});

const Payments = efx.Effect(union(enum) {
    charge: efx.Op(u64, error{Declined}!void),
});

const Traced = efx.Contract(.{ Trace, Metrics, Clock, Payments });

// ── Business logic ──────────────────────────────────────────────────

fn checkout(sc: *const efx.Scope, total_cents: u64) error{Declined}!void {
    const span = Trace.exec(sc, .start, .{ .name = "checkout" });
    var status: Status = .err;
    defer Trace.exec(sc, .end, .{ .span = span, .status = status });

    try charge(sc, span, total_cents);
    status = .ok;
}

fn charge(sc: *const efx.Scope, parent: SpanId, total_cents: u64) error{Declined}!void {
    const span = Trace.exec(sc, .start, .{ .name = "charge", .parent = parent });
    var status: Status = .err;
    defer Trace.exec(sc, .end, .{ .span = span, .status = status });

    try Payments.exec(sc, .charge, total_cents);
    status = .ok;
}

// ── Handlers ────────────────────────────────────────────────────────

/// Used unchanged in production and tests. Takes `sc` so it can dispatch to
/// `Clock` and `Metrics`. Not thread-safe; see `examples/concurrent.zig`.
const SpanTracer = struct {
    const Span = struct { name: []const u8, parent: SpanId, started_ms: i64, status: ?Status = null };

    spans: [16]Span = undefined,
    len: u32 = 0,

    pub fn start(self: *SpanTracer, sc: *const efx.Scope, args: Start) SpanId {
        if (self.len == self.spans.len) return .none;
        self.spans[self.len] = .{
            .name = args.name,
            .parent = args.parent,
            .started_ms = Clock.exec(sc, .now_ms, {}),
        };
        self.len += 1;
        return @fromBackingInt(@intCast(self.len));
    }

    pub fn end(self: *SpanTracer, sc: *const efx.Scope, args: End) void {
        if (args.span == .none) return;
        const span = self.get(args.span);
        span.status = args.status;
        Metrics.exec(sc, .observe, .{
            .name = span.name,
            .value_ms = @intCast(Clock.exec(sc, .now_ms, {}) - span.started_ms),
        });
    }

    fn get(self: *SpanTracer, id: SpanId) *Span {
        return &self.spans[@backingInt(id) - 1];
    }
};

const NoopTracer = struct {
    pub fn start(_: *NoopTracer, _: Start) SpanId {
        return .none;
    }
    pub fn end(_: *NoopTracer, _: End) void {}
};

const StderrMetrics = struct {
    pub fn observe(_: *StderrMetrics, sample: Sample) void {
        std.debug.print("{s}: {d}ms\n", .{ sample.name, sample.value_ms });
    }
};

const SystemClock = struct {
    io: std.Io,

    pub fn now_ms(self: *SystemClock) i64 {
        return std.Io.Clock.Timestamp.now(self.io, .awake).raw.toMilliseconds();
    }
};

const SlowGateway = struct {
    io: std.Io,

    pub fn charge(self: *SlowGateway, total_cents: u64) error{Declined}!void {
        self.io.sleep(.fromMilliseconds(20), .awake) catch return error.Declined;
        if (total_cents == 0) return error.Declined;
    }
};

const VirtualClock = struct {
    now: i64 = 0,

    pub fn now_ms(self: *VirtualClock) i64 {
        return self.now;
    }
};

/// Advances virtual time, standing in for a slow network call.
const FakeGateway = struct {
    clock: *VirtualClock,
    latency_ms: i64,
    decline: bool = false,

    pub fn charge(self: *FakeGateway, _: u64) error{Declined}!void {
        self.clock.now += self.latency_ms;
        if (self.decline) return error.Declined;
    }
};

const TestMetrics = struct {
    samples: [8]Sample = undefined,
    len: usize = 0,

    pub fn observe(self: *TestMetrics, sample: Sample) void {
        self.samples[self.len] = sample;
        self.len += 1;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "spans nest, and durations come from the clock" {
    var tracer = SpanTracer{};
    var metrics = TestMetrics{};
    var clock = VirtualClock{};
    var gateway = FakeGateway{ .clock = &clock, .latency_ms = 150 };
    const sc = Traced.init(.{
        .{ Trace, &tracer },
        .{ Metrics, &metrics },
        .{ Clock, &clock },
        .{ Payments, &gateway },
    });

    try checkout(&sc, 2599);

    try std.testing.expectEqualStrings("charge", tracer.spans[1].name);
    try std.testing.expectEqual(@as(SpanId, @fromBackingInt(@intCast(1))), tracer.spans[1].parent);
    try std.testing.expectEqual(@as(?Status, .ok), tracer.spans[0].status);

    try std.testing.expectEqual(@as(usize, 2), metrics.len);
    try std.testing.expectEqualStrings("charge", metrics.samples[0].name);
    try std.testing.expectEqual(@as(u64, 150), metrics.samples[0].value_ms);
    try std.testing.expectEqual(@as(u64, 150), metrics.samples[1].value_ms);
}

test "a declined charge closes both spans as failed" {
    var tracer = SpanTracer{};
    var metrics = TestMetrics{};
    var clock = VirtualClock{};
    var gateway = FakeGateway{ .clock = &clock, .latency_ms = 0, .decline = true };
    const sc = Traced.init(.{
        .{ Trace, &tracer },
        .{ Metrics, &metrics },
        .{ Clock, &clock },
        .{ Payments, &gateway },
    });

    try std.testing.expectError(error.Declined, checkout(&sc, 100));

    try std.testing.expectEqual(@as(?Status, .err), tracer.spans[0].status);
    try std.testing.expectEqual(@as(?Status, .err), tracer.spans[1].status);
}

test "a no-op tracer turns off tracing and everything it depends on" {
    var tracer = NoopTracer{};
    var metrics = TestMetrics{};
    var clock = VirtualClock{};
    var gateway = FakeGateway{ .clock = &clock, .latency_ms = 150 };
    const sc = Traced.init(.{
        .{ Trace, &tracer },
        .{ Metrics, &metrics },
        .{ Clock, &clock },
        .{ Payments, &gateway },
    });

    try checkout(&sc, 100);

    try std.testing.expectEqual(@as(usize, 0), metrics.len);
}

// ── Main ────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    var tracer = SpanTracer{};
    var metrics = StderrMetrics{};
    var clock = SystemClock{ .io = init.io };
    var gateway = SlowGateway{ .io = init.io };
    const sc = Traced.init(.{
        .{ Trace, &tracer },
        .{ Metrics, &metrics },
        .{ Clock, &clock },
        .{ Payments, &gateway },
    });

    try checkout(&sc, 4200);
    checkout(&sc, 0) catch |err| std.debug.print("checkout failed: {t}\n", .{err});
}
