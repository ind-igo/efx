const std = @import("std");
const efx = @import("efx");
const Pool = @import("dod.zig").Pool;
const Co = @import("co.zig").Co;

const Store = efx.Effect(union(enum) { get: efx.Op(u64, error{Aborted}!u64) });
fn chase(sc: *const efx.Scope, start: u64, hops: u32) error{Aborted}!u64 {
    var k = start;
    for (0..hops) |_| k = try Store.exec(sc, .get, k);
    return k;
}

const table_len = 1 << 25; // 256 MiB of u64
var table: []u64 = undefined;
const total_lookups = 2_000_000;

const P = Pool(16384, 64 * 1024);
var pool: P = undefined;

const Direct = struct {
    pub fn get(_: *Direct, k: u64) error{Aborted}!u64 {
        return table[k];
    }
};
const Parking = struct {
    pub fn get(_: *Parking, k: u64) error{Aborted}!u64 {
        return pool.perform(k);
    }
};
const Y = Co(u64, u64, u64);
const Yielding = struct {
    k: *Y,
    pub fn get(self: *Yielding, key: u64) error{Aborted}!u64 {
        return self.k.perform(key);
    }
};

const Ctx = struct { sc: *const efx.Scope, hops: u32, sum: u64 = 0 };
fn task(p: *P, input: u64) void {
    const c: *Ctx = @ptrCast(@alignCast(p.user));
    // Not `c.sum +%= chase(...)`: that loads c.sum before the call parks.
    const r = chase(c.sc, input, c.hops) catch unreachable;
    c.sum +%= r;
}
fn batchPlain(_: *anyopaque, keys: []const u64, out: []u64) void {
    for (keys, out) |k, *o| o.* = table[k];
}
fn batchPrefetch(_: *anyopaque, keys: []const u64, out: []u64) void {
    for (keys) |k| @prefetch(&table[k], .{});
    for (keys, out) |k, *o| o.* = table[k];
}
const CoArg = struct { start: u64, hops: u32 };
fn coBody(k: *Y, raw: *anyopaque) error{Aborted}!u64 {
    const a: *CoArg = @ptrCast(@alignCast(raw));
    var h = Yielding{ .k = k };
    const sc = efx.Scope.init(.{.{ Store, &h }});
    return chase(&sc, a.start, a.hops);
}

const Case = enum { plain, effect_direct, naive_fiber, pool_batch, pool_batch_prefetch, soa_prefetch };

fn runCase(case: Case, starts: []const u64, hops: u32) !u64 {
    switch (case) {
        .plain => {
            var sum: u64 = 0;
            for (starts) |s| {
                var k = s;
                for (0..hops) |_| k = table[k];
                sum +%= k;
            }
            return sum;
        },
        .effect_direct => {
            var h = Direct{};
            const sc = efx.Scope.init(.{.{ Store, &h }});
            var sum: u64 = 0;
            for (starts) |s| sum +%= try chase(&sc, s, hops);
            return sum;
        },
        .naive_fiber => {
            var sum: u64 = 0;
            var dummy: u8 = 0;
            for (starts) |s| {
                var arg = CoArg{ .start = s, .hops = hops };
                _ = &dummy;
                var k = try Y.init(coBody, &arg);
                defer k.deinit();
                var ev = k.start();
                while (ev == .perform) ev = k.@"resume"(table[ev.perform]);
                sum +%= try ev.done;
            }
            return sum;
        },
        .pool_batch, .pool_batch_prefetch => {
            var h = Parking{};
            const sc = efx.Scope.init(.{.{ Store, &h }});
            var c = Ctx{ .sc = &sc, .hops = hops };
            pool.user = &c;
            for (starts) |s| try pool.spawn(task, s);
            var dummy: u8 = 0;
            pool.run(if (case == .pool_batch) batchPlain else batchPrefetch, &dummy);
            return c.sum;
        },
        .soa_prefetch => {
            var keys: [16384]u64 = undefined;
            @memcpy(keys[0..starts.len], starts);
            const live = keys[0..starts.len];
            for (0..hops) |_| {
                for (live) |k| @prefetch(&table[k], .{});
                for (live) |*k| k.* = table[k.*];
            }
            var sum: u64 = 0;
            for (live) |k| sum +%= k;
            return sum;
        },
    }
}

fn parkOnce(p: *P, input: u64) void {
    _ = p.perform(input) catch {};
}
fn noop(_: *P, _: u64) void {}
fn noBatch(_: *anyopaque, k: []const u64, o: []u64) void {
    @memcpy(o, k);
}
fn coNoop(_: *Y, _: *anyopaque) error{Aborted}!u64 {
    return 0;
}

fn ms(io: std.Io, t0: std.Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds));
}
fn rss() u64 {
    return @intCast(std.posix.getrusage(0).maxrss);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var it = init.minimal.args.iterate();
    _ = it.next();
    const mode = it.next() orelse "time";
    var dummy: u8 = 0;

    if (std.mem.eql(u8, mode, "mem")) {
        try pool.init(&dummy);
        const before = rss();
        const n = 10_000;
        for (0..n) |i| try pool.spawn(parkOnce, i);
        pool.tick();
        const after = rss();
        std.debug.print("parked={d} rss_delta_per_task={d} bytes page={d}\n", .{ pool.req_len, (after - before) / n, std.heap.pageSize() });
        const hot = @sizeOf(usize) + @sizeOf(u64) + @sizeOf(u16);
        std.debug.print("hot columns per task={d} bytes (+1 abort bit); handle={d} bytes; pool struct={d} KiB\n", .{ hot, @sizeOf(@import("dod.zig").Cont), @sizeOf(P) / 1024 });
        return;
    }

    table = try std.heap.page_allocator.alloc(u64, table_len);
    var rng = std.Random.DefaultPrng.init(0xEF5);
    for (table, 0..) |*t, i| t.* = i;
    var i: usize = table_len - 1;
    while (i > 0) : (i -= 1) { // Sattolo: one long cycle, so chains cannot short-circuit
        const j = rng.random().uintLessThan(usize, i);
        std.mem.swap(u64, &table[i], &table[j]);
    }
    try pool.init(&dummy);

    for ([_]u32{ 16, 256, 4096 }) |n_tasks| {
        const hops: u32 = total_lookups / n_tasks;
        var starts: [16384]u64 = undefined;
        for (starts[0..n_tasks]) |*s| s.* = rng.random().uintLessThan(u64, table_len);
        var expect: ?u64 = null;
        for (std.enums.values(Case)) |case| {
            var samples: [5]f64 = undefined;
            for (&samples) |*s| {
                const t0 = std.Io.Timestamp.now(io, .awake);
                const sum = try runCase(case, starts[0..n_tasks], hops);
                s.* = ms(io, t0) / @as(f64, @floatFromInt(hops * n_tasks));
                if (expect) |e| {
                    if (e != sum) return error.Mismatch;
                } else expect = sum;
            }
            std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
            std.debug.print("tasks={d} {s} {d:.2} {d:.2} {d:.2}\n", .{ n_tasks, @tagName(case), samples[2], samples[0], samples[4] });
        }
    }

    // Lifecycle
    const n = 1_000_000;
    {
        const t0 = std.Io.Timestamp.now(io, .awake);
        for (0..n) |_| {
            try pool.spawn(noop, 0);
            pool.run(noBatch, &dummy);
        }
        std.debug.print("lifecycle pool {d:.1}\n", .{ms(io, t0) / n});
    }
    {
        const m = 100_000;
        const t0 = std.Io.Timestamp.now(io, .awake);
        for (0..m) |_| {
            var k = try Y.init(coNoop, &dummy);
            _ = k.start();
            k.deinit();
        }
        std.debug.print("lifecycle naive {d:.1}\n", .{ms(io, t0) / m});
    }
}
