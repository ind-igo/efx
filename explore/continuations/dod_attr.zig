const std = @import("std");
const efx = @import("efx");
const dod = @import("dod.zig");
const Store = efx.Effect(union(enum) { get: efx.Op(u64, error{Aborted}!u64) });
const swap = @import("swap.zig");
const baseline = @import("baseline.zig");

fn Harness(comptime Swap: type) type {
    return struct {
        const P = dod.PoolWith(16384, 64 * 1024, .{ .Swap = Swap });
        var pool: P = undefined;
        const Parking = struct {
            pub fn get(_: *Parking, k: u64) error{Aborted}!u64 {
                return pool.perform(k);
            }
        };
        var hops: u32 = 0;
        var scope: *const efx.Scope = undefined;
        var sink: u64 = 0;
        fn raw(p: *P, input: u64) void {
            var k = input;
            for (0..hops) |_| k = p.perform(k) catch unreachable;
            sink +%= k;
        }
        fn viaEfx(_: *P, input: u64) void {
            var k = input;
            for (0..hops) |_| k = Store.exec(scope, .get, k) catch unreachable;
            sink +%= k;
        }
        fn run(io: std.Io, e: P.Entry, n: u32) !f64 {
            var d: u8 = 0;
            var h = Parking{};
            const sc = efx.Scope.init(.{.{ Store, &h }});
            scope = &sc;
            hops = 4_000_000 / n;
            var s: [7]f64 = undefined;
            for (&s) |*x| {
                for (0..n) |i| try pool.spawn(e, i);
                const t0 = std.Io.Timestamp.now(io, .awake);
                pool.run(bump, &d);
                const dt = t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
                x.* = @as(f64, @floatFromInt(dt)) / @as(f64, @floatFromInt(hops * n));
            }
            std.mem.sort(f64, &s, {}, std.sort.asc(f64));
            return s[3];
        }
    };
}

fn bump(_: *anyopaque, keys: []const u64, out: []u64) void {
    for (keys, out) |k, *o| o.* = k +% 1;
}

const Old = Harness(baseline.CallRet);
const New = Harness(swap.InlineBr);

/// Park and resume through the whole pool: queue row, batch, ready list, switch pair.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var d: u8 = 0;
    try Old.pool.init(&d);
    try New.pool.init(&d);
    std.debug.print("{s:>6} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{ "tasks", "raw old", "raw new", "efx old", "efx new" });
    for ([_]u32{ 1, 16, 256, 4096 }) |n| {
        const a = try Old.run(io, Old.raw, n);
        const b = try New.run(io, New.raw, n);
        const c = try Old.run(io, Old.viaEfx, n);
        const e = try New.run(io, New.viaEfx, n);
        std.debug.print("{d:>6} {d:>10.1} {d:>10.1} {d:>10.1} {d:>10.1}\n", .{ n, a, b, c, e });
    }
}
