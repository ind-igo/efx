//! Data-oriented algebraic effects.
//!
//!   continuation      -> a generation-checked u32 handle into a fixed pool
//!   stack             -> computed from the handle, base + index * stride
//!   perform           -> append one row to a request queue, then park
//!   handler           -> a batch transform: fn (keys, out)
//!   trace / replay    -> the same columns, kept
//!
//! No per-task allocation after init. aarch64 only; single-threaded scheduler.
const std = @import("std");

const swap = @import("swap.zig");

/// One-shot is a data check: resuming bumps the generation, so a stale handle
/// is rejected instead of corrupting a stack.
pub const Cont = packed struct(u32) { index: u16, gen: u16 };

pub const Options = struct {
    /// Number of distinct stack-top offsets, `colour_step` bytes apart.
    colours: usize = 128,
    colour_step: usize = 128,
    /// Prefetch the saved frame of the task this many resumes ahead. 0 = off.
    lookahead: usize = 8,
    /// `Swap.swap(from, to)`. `baseline.CallRet` is the old one.
    Swap: type = swap.InlineBr,
};

pub fn Pool(comptime capacity: u16, comptime stride: usize) type {
    return PoolWith(capacity, stride, .{});
}

pub fn PoolWith(comptime capacity: u16, comptime stride: usize, comptime opts: Options) type {
    return struct {
        const Self = @This();
        pub const Entry = *const fn (*Self, u64) void;
        pub const Batch = *const fn (*anyopaque, keys: []const u64, out: []u64) void;

        // Hot: touched on every switch.
        sp: [capacity]usize,
        reply: [capacity]u64,
        gen: [capacity]u16,
        aborted: [capacity]bool,

        // Warm: touched at spawn and finish.
        entry: [capacity]Entry,
        input: [capacity]u64,
        free: [capacity]u16,
        free_len: u32,

        // Run queue.
        ready: [capacity]u16,
        ready_len: u32,

        // Submission queue, as columns. `perform` appends one row.
        req_key: [capacity]u64,
        req_task: [capacity]Cont,
        req_out: [capacity]u64,
        req_len: u32,

        current: u16,
        scheduler_sp: usize,
        batches: u64,
        slab: []align(std.heap.page_size_min) u8,
        user: *anyopaque,

        var active: *Self = undefined;

        pub fn init(self: *Self, user: *anyopaque) !void {
            const slab = try std.heap.page_allocator.alignedAlloc(
                u8,
                .fromByteUnits(std.heap.page_size_min),
                @as(usize, capacity) * stride,
            );
            self.slab = slab;
            self.user = user;
            self.aborted = @splat(false);
            self.gen = @splat(0);
            self.free_len = capacity;
            self.ready_len = 0;
            self.req_len = 0;
            self.batches = 0;
            // LIFO, handing out the lowest index first: the most recently
            // finished stack is the next one reused, while it is still in cache.
            for (&self.free, 0..) |*f, i| f.* = @intCast(capacity - 1 - i);
            const page = std.heap.pageSize();
            for (0..capacity) |i| {
                const guard: *align(std.heap.page_size_min) anyopaque = @ptrCast(@alignCast(slab[i * stride ..].ptr));
                if (std.c.mprotect(guard, page, .{}) != 0) return error.GuardPageFailed;
            }
        }

        pub fn deinit(self: *Self) void {
            const page = std.heap.pageSize();
            for (0..capacity) |i| {
                const guard: *align(std.heap.page_size_min) anyopaque = @ptrCast(@alignCast(self.slab[i * stride ..].ptr));
                _ = std.c.mprotect(guard, page, .{ .READ = true, .WRITE = true });
            }
            std.heap.page_allocator.free(self.slab);
        }

        fn fiberMain() callconv(.c) noreturn {
            const self = active;
            const i = self.current;
            self.entry[i](self, self.input[i]);
            self.free[self.free_len] = i;
            self.free_len += 1;
            self.gen[i] +%= 1;
            opts.Swap.swap(&self.sp[i], &self.scheduler_sp);
            unreachable;
        }

        pub fn spawn(self: *Self, entry: Entry, input: u64) error{PoolExhausted}!void {
            if (self.free_len == 0) return error.PoolExhausted;
            self.free_len -= 1;
            const i = self.free[self.free_len];
            const top = @intFromPtr(self.slab.ptr) + (@as(usize, i) + 1) * stride -
                (@as(usize, i) % opts.colours) * opts.colour_step;
            self.sp[i] = swap.fabricate(top, @intFromPtr(&fiberMain));
            self.entry[i] = entry;
            self.input[i] = input;
            self.ready[self.ready_len] = i;
            self.ready_len += 1;
        }

        /// Computation side: append a row and park until the batch completes.
        pub fn perform(self: *Self, key: u64) error{Aborted}!u64 {
            const i = self.current;
            const n = self.req_len;
            self.req_key[n] = key;
            self.req_task[n] = .{ .index = i, .gen = self.gen[i] };
            self.req_len = n + 1;
            opts.Swap.swap(&self.sp[i], &self.scheduler_sp);
            if (self.aborted[i]) {
                self.aborted[i] = false;
                return error.Aborted;
            }
            return self.reply[i];
        }

        /// One-shot resume of a parked computation.
        pub fn complete(self: *Self, k: Cont, value: u64) error{StaleContinuation}!void {
            if (self.gen[k.index] != k.gen) return error.StaleContinuation;
            self.gen[k.index] +%= 1;
            self.reply[k.index] = value;
            self.ready[self.ready_len] = k.index;
            self.ready_len += 1;
        }

        /// Discontinue: the computation resumes with error.Aborted, so `try`
        /// propagates and its `defer`s run.
        pub fn abort(self: *Self, k: Cont) error{StaleContinuation}!void {
            if (self.gen[k.index] != k.gen) return error.StaleContinuation;
            self.gen[k.index] +%= 1;
            self.aborted[k.index] = true;
            self.ready[self.ready_len] = k.index;
            self.ready_len += 1;
        }

        /// Run everything ready until it parks or ends.
        pub fn tick(self: *Self) void {
            active = self;
            const n = self.ready_len;
            self.ready_len = 0;
            var buf: [capacity]u16 = undefined;
            @memcpy(buf[0..n], self.ready[0..n]);
            for (buf[0..n], 0..) |i, at| {
                if (opts.lookahead != 0 and at + opts.lookahead < n) {
                    const frame = self.sp[buf[at + opts.lookahead]];
                    for (0..3) |line| @prefetch(@as([*]const u8, @ptrFromInt(frame + line * 64)), .{ .rw = .write });
                }
                self.current = i;
                opts.Swap.swap(&self.scheduler_sp, &self.sp[i]);
            }
        }

        pub fn pending(self: *const Self) []const u64 {
            return self.req_key[0..self.req_len];
        }

        /// Hand every parked request to one batch transform, then resume all.
        pub fn drain(self: *Self, batch: Batch, ctx: *anyopaque) void {
            const n = self.req_len;
            if (n == 0) return;
            batch(ctx, self.req_key[0..n], self.req_out[0..n]);
            self.batches += 1;
            for (self.req_task[0..n], self.req_out[0..n]) |k, v| self.complete(k, v) catch unreachable;
            self.req_len = 0;
        }

        pub fn run(self: *Self, batch: Batch, ctx: *anyopaque) void {
            while (true) {
                self.tick();
                if (self.req_len == 0 and self.ready_len == 0) return;
                self.drain(batch, ctx);
            }
        }
    };
}
