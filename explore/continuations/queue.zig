//! Which part of a pool's park and resume costs what. Same task, same batch.
const std = @import("std");
const dod = @import("dod.zig");
const tiny = @import("tiny.zig");

fn Dod(comptime capacity: u16, comptime opts: dod.Options) type {
    return struct {
        const P = dod.PoolWith(capacity, 64 * 1024, opts);
        var pool: P = undefined;
        var hops: u32 = 0;
        var sink: u64 = 0;
        fn task(p: *P, input: u64) void {
            var k = input;
            for (0..hops) |_| k = p.perform(k) catch unreachable;
            sink +%= k;
        }
        fn bump(_: *anyopaque, keys: []const u64, out: []u64) void {
            for (keys, out) |k, *o| o.* = k +% 1;
        }
        fn setup() !void {
            var d: u8 = 0;
            try pool.init(&d);
        }
        fn once(n: u32) !void {
            var d: u8 = 0;
            for (0..n) |i| try pool.spawn(task, i);
            pool.run(bump, &d);
        }
    };
}

fn Tiny(comptime capacity: u16) type {
    return struct {
        const P = tiny.Pool(capacity, 64 * 1024);
        var pool: P = undefined;
        var hops: u32 = 0;
        var sink: u64 = 0;
        fn task(p: *P, input: u64) void {
            var k = input;
            for (0..hops) |_| k = p.perform(k) catch unreachable;
            sink +%= k;
        }
        fn bump(_: *anyopaque, values: []u64) void {
            for (values) |*v| v.* +%= 1;
        }
        fn setup() !void {
            var d: u8 = 0;
            try pool.init(&d);
        }
        fn once(n: u32) !void {
            var d: u8 = 0;
            for (0..n) |i| try pool.spawn(task, i);
            pool.run(bump, &d);
        }
    };
}

fn measure(comptime H: type, io: std.Io, n: u32) !f64 {
    H.hops = 4_000_000 / n;
    var s: [7]f64 = undefined;
    for (&s) |*x| {
        const t0 = std.Io.Timestamp.now(io, .awake);
        try H.once(n);
        const dt = t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
        x.* = @as(f64, @floatFromInt(dt)) / @as(f64, @floatFromInt(H.hops * n));
    }
    std.mem.sort(f64, &s, {}, std.sort.asc(f64));
    return s[3];
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const rows = .{
        .{ "dod 512", Dod(512, .{}) },
        .{ "dod 1024", Dod(1024, .{}) },
        .{ "dod 2048", Dod(2048, .{}) },
        .{ "dod 4096", Dod(4096, .{}) },
        .{ "dod 6000", Dod(6000, .{}) },
        .{ "dod 8192", Dod(8192, .{}) },
        .{ "dod 12000", Dod(12000, .{}) },
        .{ "dod 16384", Dod(16384, .{}) },
        .{ "tiny 16384", Tiny(16384) },
    };
    std.debug.print("{s:<15} {s:>7} {s:>7} {s:>7}\n", .{ "tasks", "1", "16", "256" });
    inline for (rows) |row| {
        try row[1].setup();
        std.debug.print("{s:<15}", .{row[0]});
        for ([_]u32{ 1, 16, 256 }) |n| std.debug.print(" {d:>7.1}", .{try measure(row[1], io, n)});
        std.debug.print("\n", .{});
    }
}
