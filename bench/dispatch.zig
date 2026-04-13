/// Dispatch overhead benchmark.
/// Measures: effect dispatch vs direct fn call vs fn pointer call.
const std = @import("std");
const fx = @import("fx");

// ── Minimal effects for benchmarking ────────────────────────────────

const Counter = fx.Effect(union(enum) {
    inc: fx.Op(u64, void),
});

const Adder = fx.Effect(union(enum) {
    add: fx.Op(u64, u64),
});

// ── Handlers ────────────────────────────────────────────────────────

const CounterHandler = struct {
    total: u64 = 0,

    pub fn inc(self: *CounterHandler, v: u64) void {
        self.total +%= v;
    }
};

const AdderHandler = struct {
    acc: u64 = 0,

    pub fn add(self: *AdderHandler, v: u64) u64 {
        self.acc +%= v;
        return self.acc;
    }
};

// ── Direct call baseline ────────────────────────────────────────────

var direct_total: u64 = 0;

fn directInc(v: u64) void {
    direct_total +%= v;
}

noinline fn directIncNoInline(v: u64) void {
    direct_total +%= v;
}

// ── Benchmark harness ───────────────────────────────────────────────

const ITERS: u64 = 100_000_000;
const WARMUP: u64 = 10_000_000;

fn bench(comptime name: []const u8, comptime f: fn (u64) void) void {
    // Warmup
    var i: u64 = 0;
    while (i < WARMUP) : (i += 1) f(i);

    // Timed
    var timer = std.time.Timer.start() catch unreachable;
    i = 0;
    while (i < ITERS) : (i += 1) f(i);
    const elapsed_ns = timer.read();

    const ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(ITERS));
    std.debug.print("  {s:<30} {d:.2} ns/op  ({d:.0}M ops/sec)\n", .{
        name,
        ns_per_op,
        @as(f64, @floatFromInt(ITERS)) / @as(f64, @floatFromInt(elapsed_ns)) * 1000.0,
    });
}

fn benchReturn(comptime name: []const u8, comptime f: fn (u64) u64) void {
    var i: u64 = 0;
    while (i < WARMUP) : (i += 1) _ = f(i);

    var timer = std.time.Timer.start() catch unreachable;
    var sink: u64 = 0;
    i = 0;
    while (i < ITERS) : (i += 1) sink +%= f(i);
    const elapsed_ns = timer.read();
    std.mem.doNotOptimizeAway(sink);

    const ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(ITERS));
    std.debug.print("  {s:<30} {d:.2} ns/op  ({d:.0}M ops/sec)\n", .{
        name,
        ns_per_op,
        @as(f64, @floatFromInt(ITERS)) / @as(f64, @floatFromInt(elapsed_ns)) * 1000.0,
    });
}

// ── Wrappers ────────────────────────────────────────────────────────

fn viaEffect(v: u64) void {
    Counter.exec(.inc, v);
}

fn viaDirect(v: u64) void {
    directIncNoInline(v);
}

var fn_ptr: *const fn (u64) void = &directIncNoInline;

fn viaFnPtr(v: u64) void {
    fn_ptr(v);
}

fn viaEffectReturn(v: u64) u64 {
    return Adder.exec(.add, v);
}

pub fn main() !void {
    // Setup
    var counter = CounterHandler{};
    var adder = AdderHandler{};
    fx.init(.{
        .{ Counter, &counter },
        .{ Adder, &adder },
    });

    std.debug.print("\nDispatch benchmark ({d}M iterations)\n\n", .{ITERS / 1_000_000});

    std.debug.print("Void operations:\n", .{});
    bench("direct fn call", viaDirect);
    bench("fn pointer call", viaFnPtr);
    bench("effect dispatch", viaEffect);

    std.debug.print("\nReturning operations:\n", .{});
    benchReturn("effect dispatch (returns u64)", viaEffectReturn);

    // Prevent optimization of handler state
    std.mem.doNotOptimizeAway(counter.total);
    std.mem.doNotOptimizeAway(adder.acc);
    std.mem.doNotOptimizeAway(direct_total);
}
