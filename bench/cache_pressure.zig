/// Cache pressure benchmark.
/// Tests dispatch cost when alternating between many effects,
/// forcing vtables to compete for cache lines.
const std = @import("std");
const fx = @import("fx");

// ── 16 independent effects ──────────────────────────────────────────
// Each has its own vtable in a different static location.

const E01 = fx.Effect(union(enum) { op: fx.Op(u64, u64) });
const E02 = fx.Effect(union(enum) { op: fx.Op(u64, u64) });
const E03 = fx.Effect(union(enum) { op: fx.Op(u64, u64) });
const E04 = fx.Effect(union(enum) { op: fx.Op(u64, u64) });
const E05 = fx.Effect(union(enum) { op: fx.Op(u64, u64) });
const E06 = fx.Effect(union(enum) { op: fx.Op(u64, u64) });
const E07 = fx.Effect(union(enum) { op: fx.Op(u64, u64) });
const E08 = fx.Effect(union(enum) { op: fx.Op(u64, u64) });
const E09 = fx.Effect(union(enum) { op: fx.Op(u64, u64) });
const E10 = fx.Effect(union(enum) { op: fx.Op(u64, u64) });
const E11 = fx.Effect(union(enum) { op: fx.Op(u64, u64) });
const E12 = fx.Effect(union(enum) { op: fx.Op(u64, u64) });
const E13 = fx.Effect(union(enum) { op: fx.Op(u64, u64) });
const E14 = fx.Effect(union(enum) { op: fx.Op(u64, u64) });
const E15 = fx.Effect(union(enum) { op: fx.Op(u64, u64) });
const E16 = fx.Effect(union(enum) { op: fx.Op(u64, u64) });

// ── Handler: same shape for all ─────────────────────────────────────

fn MakeHandler(comptime id: u64) type {
    return struct {
        acc: u64 = 0,
        pub fn op(self: *@This(), v: u64) u64 {
            self.acc +%= v +% id;
            return self.acc;
        }
    };
}

const H01 = MakeHandler(1);
const H02 = MakeHandler(2);
const H03 = MakeHandler(3);
const H04 = MakeHandler(4);
const H05 = MakeHandler(5);
const H06 = MakeHandler(6);
const H07 = MakeHandler(7);
const H08 = MakeHandler(8);
const H09 = MakeHandler(9);
const H10 = MakeHandler(10);
const H11 = MakeHandler(11);
const H12 = MakeHandler(12);
const H13 = MakeHandler(13);
const H14 = MakeHandler(14);
const H15 = MakeHandler(15);
const H16 = MakeHandler(16);

// ── Benchmarks ──────────────────────────────────────────────────────

var io_instance: std.Io.Threaded = .init_single_threaded;
var io: std.Io = undefined;

const ITERS: u64 = 50_000_000;

fn benchSingle() void {
    const start = std.Io.Timestamp.now(io, .awake);
    var sink: u64 = 0;
    var i: u64 = 0;
    while (i < ITERS) : (i += 1) {
        sink +%= E01.exec(.op, i);
    }
    const elapsed: u64 = @intCast(start.untilNow(io, .awake).nanoseconds);
    std.mem.doNotOptimizeAway(sink);
    printResult("1 effect (hot cache)", elapsed, ITERS);
}

fn benchTwo() void {
    const start = std.Io.Timestamp.now(io, .awake);
    var sink: u64 = 0;
    var i: u64 = 0;
    while (i < ITERS) : (i += 1) {
        sink +%= E01.exec(.op, i);
        sink +%= E02.exec(.op, i);
    }
    const elapsed: u64 = @intCast(start.untilNow(io, .awake).nanoseconds);
    std.mem.doNotOptimizeAway(sink);
    printResult("2 effects alternating", elapsed, ITERS * 2);
}

fn benchFour() void {
    const start = std.Io.Timestamp.now(io, .awake);
    var sink: u64 = 0;
    var i: u64 = 0;
    while (i < ITERS) : (i += 1) {
        sink +%= E01.exec(.op, i);
        sink +%= E02.exec(.op, i);
        sink +%= E03.exec(.op, i);
        sink +%= E04.exec(.op, i);
    }
    const elapsed: u64 = @intCast(start.untilNow(io, .awake).nanoseconds);
    std.mem.doNotOptimizeAway(sink);
    printResult("4 effects alternating", elapsed, ITERS * 4);
}

fn benchEight() void {
    const start = std.Io.Timestamp.now(io, .awake);
    var sink: u64 = 0;
    var i: u64 = 0;
    while (i < ITERS) : (i += 1) {
        sink +%= E01.exec(.op, i);
        sink +%= E02.exec(.op, i);
        sink +%= E03.exec(.op, i);
        sink +%= E04.exec(.op, i);
        sink +%= E05.exec(.op, i);
        sink +%= E06.exec(.op, i);
        sink +%= E07.exec(.op, i);
        sink +%= E08.exec(.op, i);
    }
    const elapsed: u64 = @intCast(start.untilNow(io, .awake).nanoseconds);
    std.mem.doNotOptimizeAway(sink);
    printResult("8 effects alternating", elapsed, ITERS * 8);
}

fn benchSixteen() void {
    const start = std.Io.Timestamp.now(io, .awake);
    var sink: u64 = 0;
    var i: u64 = 0;
    while (i < ITERS) : (i += 1) {
        sink +%= E01.exec(.op, i);
        sink +%= E02.exec(.op, i);
        sink +%= E03.exec(.op, i);
        sink +%= E04.exec(.op, i);
        sink +%= E05.exec(.op, i);
        sink +%= E06.exec(.op, i);
        sink +%= E07.exec(.op, i);
        sink +%= E08.exec(.op, i);
        sink +%= E09.exec(.op, i);
        sink +%= E10.exec(.op, i);
        sink +%= E11.exec(.op, i);
        sink +%= E12.exec(.op, i);
        sink +%= E13.exec(.op, i);
        sink +%= E14.exec(.op, i);
        sink +%= E15.exec(.op, i);
        sink +%= E16.exec(.op, i);
    }
    const elapsed: u64 = @intCast(start.untilNow(io, .awake).nanoseconds);
    std.mem.doNotOptimizeAway(sink);
    printResult("16 effects alternating", elapsed, ITERS * 16);
}

fn printResult(name: []const u8, elapsed_ns: u64, total_ops: u64) void {
    const ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(total_ops));
    const mops = @as(f64, @floatFromInt(total_ops)) / @as(f64, @floatFromInt(elapsed_ns)) * 1000.0;
    std.debug.print("  {s:<30} {d:.2} ns/op  ({d:.0}M ops/sec)\n", .{ name, ns_per_op, mops });
}

pub fn main() !void {
    io = io_instance.io();

    var h01 = H01{};
    var h02 = H02{};
    var h03 = H03{};
    var h04 = H04{};
    var h05 = H05{};
    var h06 = H06{};
    var h07 = H07{};
    var h08 = H08{};
    var h09 = H09{};
    var h10 = H10{};
    var h11 = H11{};
    var h12 = H12{};
    var h13 = H13{};
    var h14 = H14{};
    var h15 = H15{};
    var h16 = H16{};

    fx.init(.{
        .{ E01, &h01 }, .{ E02, &h02 }, .{ E03, &h03 }, .{ E04, &h04 },
        .{ E05, &h05 }, .{ E06, &h06 }, .{ E07, &h07 }, .{ E08, &h08 },
        .{ E09, &h09 }, .{ E10, &h10 }, .{ E11, &h11 }, .{ E12, &h12 },
        .{ E13, &h13 }, .{ E14, &h14 }, .{ E15, &h15 }, .{ E16, &h16 },
    });

    std.debug.print("\nCache pressure benchmark ({d}M iterations per effect)\n\n", .{ITERS / 1_000_000});

    benchSingle();
    benchTwo();
    benchFour();
    benchEight();
    benchSixteen();
}
