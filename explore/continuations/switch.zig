//! What a stack switch costs, and where that cost comes from.
//!
//! Two stacks ping-pong with no queue or scheduler between them. The switch
//! sits `depth` real call frames below the fiber's loop, so the return chain
//! after each resume has that many returns to predict.
const std = @import("std");

const swap = @import("swap.zig");
const CallRet = @import("baseline.zig").CallRet;
const InlineBr = swap.InlineBr;
const fabricate = swap.fabricate;

comptime {
    asm (
        \\.text
        \\.p2align 2
        \\.globl _sw_call_br
        \\_sw_call_br:
        \\  sub sp, sp, #0xa0
        \\  stp x19, x20, [sp, #0x00]
        \\  stp x21, x22, [sp, #0x10]
        \\  stp x23, x24, [sp, #0x20]
        \\  stp x25, x26, [sp, #0x30]
        \\  stp x27, x28, [sp, #0x40]
        \\  stp x29, x30, [sp, #0x50]
        \\  stp d8,  d9,  [sp, #0x60]
        \\  stp d10, d11, [sp, #0x70]
        \\  stp d12, d13, [sp, #0x80]
        \\  stp d14, d15, [sp, #0x90]
        \\  mov x9, sp
        \\  str x9, [x0]
        \\  ldr x9, [x1]
        \\  mov sp, x9
        \\  ldp x19, x20, [sp, #0x00]
        \\  ldp x21, x22, [sp, #0x10]
        \\  ldp x23, x24, [sp, #0x20]
        \\  ldp x25, x26, [sp, #0x30]
        \\  ldp x27, x28, [sp, #0x40]
        \\  ldp x29, x30, [sp, #0x50]
        \\  ldp d8,  d9,  [sp, #0x60]
        \\  ldp d10, d11, [sp, #0x70]
        \\  ldp d12, d13, [sp, #0x80]
        \\  ldp d14, d15, [sp, #0x90]
        \\  add sp, sp, #0xa0
        \\  br x30
    );
}
extern fn sw_call_br(from: *usize, to: *const usize) callconv(.c) void;

const CallBr = struct {
    pub const name = "call+br";
    pub fn swap(from: *usize, to: *const usize) void {
        sw_call_br(from, to);
    }
};

/// Saves only sp, pc and fp. Every other register is declared clobbered, so the
/// compiler spills what is live and the enclosing function's prologue saves
/// the callee-saved registers it must preserve for its own caller.
const InlineMin = struct {
    pub const name = "inline+min";
    pub inline fn swap(from: *usize, to: *const usize) void {
        var o0: usize = undefined;
        var o1: usize = undefined;
        asm volatile (
            \\adr x9, 1f
            \\sub sp, sp, #0x10
            \\stp x29, x9, [sp]
            \\mov x9, sp
            \\str x9, [x0]
            \\ldr x9, [x1]
            \\mov sp, x9
            \\ldp x29, x9, [sp]
            \\add sp, sp, #0x10
            \\br x9
            \\1:
            : [o0] "={x0}" (o0),
              [o1] "={x1}" (o1),
            : [from] "{x0}" (from),
              [to] "{x1}" (to),
            : .{
              .memory = true,
              .nzcv = true,
              .x2 = true,
              .x3 = true,
              .x4 = true,
              .x5 = true,
              .x6 = true,
              .x7 = true,
              .x8 = true,
              .x9 = true,
              .x10 = true,
              .x11 = true,
              .x12 = true,
              .x13 = true,
              .x14 = true,
              .x15 = true,
              .x16 = true,
              .x17 = true,
              .x19 = true,
              .x20 = true,
              .x21 = true,
              .x22 = true,
              .x23 = true,
              .x24 = true,
              .x25 = true,
              .x26 = true,
              .x27 = true,
              .x28 = true,
              .lr = true,
              .v0 = true,
              .v1 = true,
              .v2 = true,
              .v3 = true,
              .v4 = true,
              .v5 = true,
              .v6 = true,
              .v7 = true,
              .v8 = true,
              .v9 = true,
              .v10 = true,
              .v11 = true,
              .v12 = true,
              .v13 = true,
              .v14 = true,
              .v15 = true,
              .v16 = true,
              .v17 = true,
              .v18 = true,
              .v19 = true,
              .v20 = true,
              .v21 = true,
              .v22 = true,
              .v23 = true,
              .v24 = true,
              .v25 = true,
              .v26 = true,
              .v27 = true,
              .v28 = true,
              .v29 = true,
              .v30 = true,
              .v31 = true,
            });
    }

    pub fn fabricateFrame(top: usize, entry: usize) usize {
        const sp = top - 0x10;
        const frame: [*]usize = @ptrFromInt(sp);
        frame[0] = 0;
        frame[1] = entry;
        return sp;
    }
};

/// Three frames that save nothing: each caller spills only what is live.
const Unsaved = struct {
    pub const cc: std.lang.CallingConvention = .{ .aarch64_preserve_none = .{} };
    var scheduler: usize = 0;
    var fiber: usize = 0;
    var stack: [64 * 1024]u8 align(16) = undefined;

    fn down1(x: u64) callconv(cc) u64 {
        InlineMin.swap(&fiber, &scheduler);
        return x +% 1;
    }
    fn down2(x: u64) callconv(cc) u64 {
        return @call(.never_inline, down1, .{x}) +% 1;
    }
    fn down3(x: u64) callconv(cc) u64 {
        return @call(.never_inline, down2, .{x}) +% 1;
    }

    fn entry() callconv(.c) noreturn {
        var x: u64 = 0;
        while (true) x = @call(.never_inline, down3, .{x});
    }

    fn measure(io: std.Io, pairs: u64) f64 {
        fiber = InlineMin.fabricateFrame(@intFromPtr(&stack) + stack.len, @intFromPtr(&entry));
        const t0 = std.Io.Timestamp.now(io, .awake);
        var i: u64 = 0;
        while (i < pairs) : (i += 1) InlineMin.swap(&scheduler, &fiber);
        const dt = t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
        return @as(f64, @floatFromInt(dt)) / @as(f64, @floatFromInt(pairs));
    }
};

fn frameFor(comptime S: type, top: usize, entry: usize) usize {
    return if (@hasDecl(S, "fabricateFrame")) S.fabricateFrame(top, entry) else fabricate(top, entry);
}

fn Ping(comptime S: type, comptime depth: u32) type {
    return struct {
        var scheduler: usize = 0;
        var fiber: usize = 0;
        var stack: [64 * 1024]u8 align(16) = undefined;

        fn down(comptime d: u32, x: u64) u64 {
            if (d == 1) {
                S.swap(&fiber, &scheduler);
                return x +% 1;
            }
            return @call(.never_inline, down, .{ d - 1, x }) +% 1;
        }

        fn entry() callconv(.c) noreturn {
            var x: u64 = 0;
            while (true) {
                if (depth == 0) {
                    S.swap(&fiber, &scheduler);
                    x +%= 1;
                } else {
                    x = @call(.never_inline, down, .{ depth, x });
                }
            }
        }

        fn measure(io: std.Io, pairs: u64) f64 {
            fiber = frameFor(S, @intFromPtr(&stack) + stack.len, @intFromPtr(&entry));
            const t0 = std.Io.Timestamp.now(io, .awake);
            var i: u64 = 0;
            while (i < pairs) : (i += 1) S.swap(&scheduler, &fiber);
            const dt = t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
            return @as(f64, @floatFromInt(dt)) / @as(f64, @floatFromInt(pairs));
        }
    };
}

/// Several fibers, each parking at its own call site through `depth` frames.
/// One scheduler site resumes them, so its indirect branch has `sites` targets
/// and the return-address stack holds the previous fiber's chain.
fn Mixed(comptime S: type, comptime sites: u32, comptime depth: u32) type {
    return struct {
        var scheduler: usize = 0;
        var fibers: [sites]usize = undefined;
        var stacks: [sites][64 * 1024]u8 align(16) = undefined;

        fn down(comptime k: u32, comptime d: u32, x: u64) u64 {
            if (d == 1) {
                S.swap(&fibers[k], &scheduler);
                return x +% (2 * k + 1);
            }
            return @call(.never_inline, down, .{ k, d - 1, x }) +% (2 * k + 3);
        }

        fn Entry(comptime k: u32) type {
            return struct {
                fn run() callconv(.c) noreturn {
                    var x: u64 = k;
                    while (true) x = @call(.never_inline, down, .{ k, depth, x });
                }
            };
        }

        fn measure(io: std.Io, order: []const u8) f64 {
            inline for (0..sites) |k| {
                const top = @intFromPtr(&stacks[k]) + stacks[k].len;
                fibers[k] = frameFor(S, top, @intFromPtr(&Entry(k).run));
            }
            const t0 = std.Io.Timestamp.now(io, .awake);
            for (order) |k| S.swap(&scheduler, &fibers[k]);
            const dt = t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
            return @as(f64, @floatFromInt(dt)) / @as(f64, @floatFromInt(order.len));
        }
    };
}

/// `n` fibers on stacks `stride` apart, resumed in order with no queue: the
/// switch pair plus the cost of a different stack on every resume.
fn Sweep(comptime S: type) type {
    return struct {
        var scheduler: usize = 0;
        var fibers: []usize = undefined;
        var current: usize = 0;

        noinline fn park(x: u64) u64 {
            S.swap(&fibers[current], &scheduler);
            return x +% 1;
        }

        fn entry() callconv(.c) noreturn {
            var x: u64 = 0;
            while (true) x = @call(.never_inline, park, .{x});
        }

        fn measure(io: std.Io, gpa: std.mem.Allocator, n: usize, stride: usize) !f64 {
            const page = std.heap.page_size_min;
            const slab = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(page), n * stride);
            defer std.heap.page_allocator.free(slab);
            fibers = try gpa.alloc(usize, n);
            defer gpa.free(fibers);
            for (fibers, 0..) |*f, i| {
                const colour = (i % 128) * 128 % stride;
                f.* = frameFor(S, @intFromPtr(slab.ptr) + (i + 1) * stride - colour, @intFromPtr(&entry));
            }
            const rounds = 8_000_000 / n;
            const t0 = std.Io.Timestamp.now(io, .awake);
            for (0..rounds) |_| {
                for (fibers, 0..) |*f, i| {
                    current = i;
                    S.swap(&scheduler, f);
                }
            }
            const dt = t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
            return @as(f64, @floatFromInt(dt)) / @as(f64, @floatFromInt(rounds * n));
        }
    };
}

const depths = [_]u32{ 0, 1, 2, 3, 4, 6, 8, 12, 16 };
const variants = [_]type{ CallRet, CallBr, InlineBr, InlineMin };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    std.debug.print("one fiber, one site; ns per park+resume, by depth\n{s:<11}", .{""});
    for (depths) |d| std.debug.print(" {d:>6}", .{d});
    std.debug.print("\n", .{});
    inline for (variants) |S| {
        std.debug.print("{s:<11}", .{S.name});
        inline for (depths) |d| {
            var samples: [5]f64 = undefined;
            for (&samples) |*x| x.* = Ping(S, d).measure(io, 10_000_000);
            std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
            std.debug.print(" {d:>6.1}", .{samples[2]});
        }
        std.debug.print("\n", .{});
    }

    var unsaved: [5]f64 = undefined;
    for (&unsaved) |*x| x.* = Unsaved.measure(io, 10_000_000);
    std.mem.sort(f64, &unsaved, {}, std.sort.asc(f64));
    std.debug.print("preserve_none, depth 3: {d:.1}\n", .{unsaved[2]});

    std.debug.print("\nn fibers, no queue; ns per park+resume\n{s:<11} {s:>7}", .{ "", "stride" });
    const counts = [_]usize{ 1, 16, 256, 4096 };
    for (counts) |n| std.debug.print(" {d:>6}", .{n});
    std.debug.print("\n", .{});
    inline for ([_]type{ CallRet, InlineBr }) |S| {
        for ([_]usize{ 16 * 1024, 64 * 1024 }) |stride| {
            std.debug.print("{s:<11} {d:>6}K", .{ S.name, stride / 1024 });
            for (counts) |n| {
                var samples: [5]f64 = undefined;
                for (&samples) |*x| x.* = try Sweep(S).measure(io, init.gpa, n, stride);
                std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
                std.debug.print(" {d:>6.1}", .{samples[2]});
            }
            std.debug.print("\n", .{});
        }
    }

    const order = try init.gpa.alloc(u8, 1 << 22);
    defer init.gpa.free(order);
    var rng = std.Random.DefaultPrng.init(0xEF5);
    std.debug.print("\neight fibers at eight sites, depth 3; ns per park+resume\n{s:<11} {s:>6} {s:>6}\n", .{ "", "cycle", "random" });
    inline for (variants) |S| {
        std.debug.print("{s:<11}", .{S.name});
        for (0..2) |random| {
            for (order, 0..) |*o, i| o.* = if (random == 1) rng.random().int(u3) else @intCast(i % 8);
            var samples: [5]f64 = undefined;
            for (&samples) |*x| x.* = Mixed(S, 8, 3).measure(io, order);
            std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
            std.debug.print(" {d:>6.1}", .{samples[2]});
        }
        std.debug.print("\n", .{});
    }
}
