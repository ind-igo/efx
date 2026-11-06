const std = @import("std");
const efx = @import("efx");
const dod = @import("dod.zig");

const Store = efx.Effect(union(enum) { get: efx.Op(u64, error{Aborted}!u64) });
fn chase(sc: *const efx.Scope, start: u64, hops: u32) error{Aborted}!u64 {
    var k = start;
    for (0..hops) |_| k = try Store.exec(sc, .get, k);
    return k;
}
var table: []u64 = undefined;

fn batchTable(_: *anyopaque, keys: []const u64, out: []u64) void {
    for (keys) |k| @prefetch(&table[k], .{});
    for (keys, out) |k, *o| o.* = table[k];
}
fn batchNoMem(_: *anyopaque, keys: []const u64, out: []u64) void {
    for (keys, out) |k, *o| o.* = (k *% 0x9E3779B97F4A7C15) >> 39;
}

fn Harness(comptime opts: dod.Options) type {
    return struct {
        const P = dod.PoolWith(16384, 64 * 1024, opts);
        var pool: P = undefined;
        const Parking = struct {
            pub fn get(_: *Parking, k: u64) error{Aborted}!u64 {
                return pool.perform(k);
            }
        };
        const Ctx = struct { sc: *const efx.Scope, hops: u32, sum: u64 = 0 };
        fn task(p: *P, input: u64) void {
            const c: *Ctx = @ptrCast(@alignCast(p.user));
            const r = chase(c.sc, input, c.hops) catch unreachable;
            c.sum +%= r;
        }
        fn go(starts: []const u64, hops: u32, batch: P.Batch) !u64 {
            var h = Parking{};
            const sc = efx.Scope.init(.{.{ Store, &h }});
            var c = Ctx{ .sc = &sc, .hops = hops };
            pool.user = &c;
            for (starts) |s| try pool.spawn(task, s);
            var d: u8 = 0;
            pool.run(batch, &d);
            return c.sum;
        }
    };
}

const Base = Harness(.{ .colours = 1, .lookahead = 0 });
const Colour = Harness(.{ .colours = 128, .lookahead = 0 });
const Look = Harness(.{ .colours = 1, .lookahead = 8 });
const Both = Harness(.{ .colours = 128, .lookahead = 8 });
const Old = Harness(.{ .colours = 128, .lookahead = 8, .Swap = @import("baseline.zig").CallRet });

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    table = try std.heap.page_allocator.alloc(u64, 1 << 25);
    var rng = std.Random.DefaultPrng.init(0xEF5);
    for (table, 0..) |*t, i| t.* = i;
    var i: usize = table.len - 1;
    while (i > 0) : (i -= 1) {
        const j = rng.random().uintLessThan(usize, i);
        std.mem.swap(u64, &table[i], &table[j]);
    }
    var d: u8 = 0;
    try Base.pool.init(&d);
    try Colour.pool.init(&d);
    try Look.pool.init(&d);
    try Both.pool.init(&d);
    try Old.pool.init(&d);

    const names = [_][]const u8{ "base", "colour", "lookahead", "both", "both_callret" };
    for ([_]u32{ 16, 64, 256, 1024, 4096 }) |n| {
        const hops: u32 = 2_000_000 / n;
        var starts: [4096]u64 = undefined;
        for (starts[0..n]) |*s| s.* = rng.random().uintLessThan(u64, table.len);
        for (0..2) |m| {
            for (names, 0..) |name, v| {
                var samples: [5]f64 = undefined;
                var expect: ?u64 = null;
                for (&samples) |*x| {
                    const t0 = std.Io.Timestamp.now(io, .awake);
                    const b = starts[0..n];
                    const sum = switch (v) {
                        0 => try Base.go(b, hops, if (m == 0) batchTable else batchNoMem),
                        1 => try Colour.go(b, hops, if (m == 0) batchTable else batchNoMem),
                        2 => try Look.go(b, hops, if (m == 0) batchTable else batchNoMem),
                        3 => try Both.go(b, hops, if (m == 0) batchTable else batchNoMem),
                        else => try Old.go(b, hops, if (m == 0) batchTable else batchNoMem),
                    };
                    const dt = t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
                    x.* = @as(f64, @floatFromInt(dt)) / @as(f64, @floatFromInt(hops * n));
                    if (expect) |e| {
                        if (e != sum) return error.Mismatch;
                    } else expect = sum;
                }
                std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
                std.debug.print("{d} {s} {s} {d:.2}\n", .{ n, if (m == 0) "table" else "nomem", name, samples[2] });
            }
        }
    }
}
