//! `src/cont.zig` against the `dod.zig` prototype, and where efx's cost inside a
//! pool comes from. Each task performs in a loop; the driver answers every row.
const std = @import("std");
const efx = @import("efx");
const cont = @import("efx_cont");
const dod = @import("dod.zig");

const capacity = 4096;
const Cancelable = cont.Cancelable;

// ── Module under test ───────────────────────────────────────────────
const P = cont.Pool(.{ .Request = u64, .Reply = u64, .capacity = capacity });
var pool: P = undefined;

const Store = efx.Effect(union(enum) { get: efx.Op(u64, Cancelable!u64) });
const Parking = struct {
    pub fn get(_: *Parking, k: u64) Cancelable!u64 {
        return pool.perform(k);
    }
};

const Via = enum { direct, fnptr, effect, shaped };

fn viaPtr(k: u64) Cancelable!u64 {
    return pool.perform(k);
}
var ptr: *const fn (u64) Cancelable!u64 = &viaPtr;

// exec's shape with no efx: state, scope and argument, through a table, to a
// separate trampoline frame that calls the handler.
const Row = struct { state: *anyopaque, vt: *const VT };
const VT = struct { get: *const fn (*anyopaque, *const [16]Row, u64) Cancelable!u64 };
noinline fn shapedGet(k: u64) Cancelable!u64 {
    return pool.perform(k);
}
fn shapedTramp(_: *anyopaque, _: *const [16]Row, k: u64) Cancelable!u64 {
    return shapedGet(k);
}
const shaped_vt = VT{ .get = &shapedTramp };
noinline fn loopShaped(rows: *const [16]Row, n: u64) void {
    var x: u64 = 1;
    for (0..n) |_| {
        const r = rows[3];
        x = r.vt.get(r.state, rows, x) catch return;
    }
}

noinline fn loopDirect(n: u64) void {
    var x: u64 = 1;
    for (0..n) |_| x = pool.perform(x) catch return;
}
noinline fn loopPtr(n: u64) void {
    var x: u64 = 1;
    for (0..n) |_| x = ptr(x) catch return;
}
noinline fn loopEffect(sc: *const efx.Scope, n: u64) void {
    var x: u64 = 1;
    for (0..n) |_| x = Store.exec(sc, .get, x) catch return;
}

fn elapsed(io: std.Io, t0: std.Io.Timestamp, ops: u64) f64 {
    const d = t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    return @as(f64, @floatFromInt(d)) / @as(f64, @floatFromInt(ops));
}

fn runCont(io: std.Io, via: Via, tasks: usize, total: u64) !f64 {
    var h = Parking{};
    const sc = efx.Scope.init(.{.{ Store, &h }});
    var token: u8 = 0;
    var rows: [16]Row = @splat(.{ .state = &token, .vt = &shaped_vt });
    const each = total / tasks;
    for (0..tasks) |_| switch (via) {
        .direct => try pool.spawn(loopDirect, .{each}),
        .fnptr => try pool.spawn(loopPtr, .{each}),
        .effect => try pool.spawn(loopEffect, .{ &sc, each }),
        .shaped => try pool.spawn(loopShaped, .{ &rows, each }),
    };
    const t0 = std.Io.Timestamp.now(io, .awake);
    while (pool.live() != 0) {
        pool.tick();
        const b = pool.take();
        for (b.requests, b.conts) |r, k| try pool.complete(k, r +% 1);
    }
    return elapsed(io, t0, each * tasks);
}

// ── Prototype ───────────────────────────────────────────────────────
const D = dod.Pool(capacity, 64 * 1024);
var old: D = undefined;
const OldStore = efx.Effect(union(enum) { get: efx.Op(u64, error{Aborted}!u64) });
const OldParking = struct {
    pub fn get(_: *OldParking, k: u64) error{Aborted}!u64 {
        return old.perform(k);
    }
};
var old_sc: *const efx.Scope = undefined;
fn oldDirect(p: *D, n: u64) void {
    var x: u64 = 1;
    for (0..n) |_| x = p.perform(x) catch return;
}
fn oldEffect(_: *D, n: u64) void {
    var x: u64 = 1;
    for (0..n) |_| x = OldStore.exec(old_sc, .get, x) catch return;
}
fn oldBatch(_: *anyopaque, keys: []const u64, out: []u64) void {
    for (keys, out) |k, *o| o.* = k +% 1;
}
fn runOld(io: std.Io, effect: bool, tasks: usize, total: u64) !f64 {
    var h = OldParking{};
    const sc = efx.Scope.init(.{.{ OldStore, &h }});
    old_sc = &sc;
    const each = total / tasks;
    for (0..tasks) |_| try old.spawn(if (effect) oldEffect else oldDirect, each);
    var dummy: u8 = 0;
    const t0 = std.Io.Timestamp.now(io, .awake);
    old.run(oldBatch, &dummy);
    return elapsed(io, t0, each * tasks);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    try pool.init();
    defer pool.deinit();
    var token: u8 = 0;
    try old.init(&token);
    defer old.deinit();
    const total = 20_000_000;
    std.debug.print("ns per park+resume, best of 5\n{s:>6} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{ "tasks", "dod", "dod+efx", "cont", "cont+ptr", "cont+shape", "cont+efx" });
    for ([_]usize{ 1, 16, 256, 4096 }) |n| {
        var best: [6]f64 = @splat(1e9);
        for (0..5) |_| {
            best[0] = @min(best[0], try runOld(io, false, n, total));
            best[1] = @min(best[1], try runOld(io, true, n, total));
            best[2] = @min(best[2], try runCont(io, .direct, n, total));
            best[3] = @min(best[3], try runCont(io, .fnptr, n, total));
            best[4] = @min(best[4], try runCont(io, .shaped, n, total));
            best[5] = @min(best[5], try runCont(io, .effect, n, total));
        }
        std.debug.print("{d:>6} {d:>10.1} {d:>10.1} {d:>10.1} {d:>10.1} {d:>10.1} {d:>10.1}\n", .{ n, best[0], best[1], best[2], best[3], best[4], best[5] });
    }
}
