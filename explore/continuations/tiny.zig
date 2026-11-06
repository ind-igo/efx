//! The smallest pool that parks computations on an effect and batches them.
//!
//! One queue. A row holds a request until the batch runs and the reply after,
//! so `batch` transforms `values` in place. A resumed task reads its row before
//! it can append, and appends at most one row, so it only overwrites rows that
//! are already consumed. There is no ready list and no reply column.
const std = @import("std");
const swap = @import("swap.zig");

pub fn Pool(comptime capacity: u16, comptime stride: usize) type {
    return struct {
        const Self = @This();
        pub const Entry = *const fn (*Self, u64) void;
        pub const Batch = *const fn (*anyopaque, values: []u64) void;

        sp: [capacity]usize,
        values: [capacity]u64,
        who: [capacity]u16,
        free: [capacity]u16,
        free_len: u32,
        len: u32,
        at: u32,
        current: u16,
        cancelled: bool,
        scheduler: usize,
        entry: Entry,
        input: u64,
        slab: []align(std.heap.page_size_min) u8,
        user: *anyopaque,

        var active: *Self = undefined;

        pub fn init(self: *Self, user: *anyopaque) !void {
            self.slab = try std.heap.page_allocator.alignedAlloc(
                u8,
                .fromByteUnits(std.heap.page_size_min),
                @as(usize, capacity) * stride,
            );
            self.user = user;
            self.len = 0;
            self.cancelled = false;
            self.free_len = capacity;
            for (&self.free, 0..) |*f, i| f.* = @intCast(capacity - 1 - i);
            const page = std.heap.pageSize();
            for (0..capacity) |i| {
                const guard: *align(std.heap.page_size_min) anyopaque = @ptrCast(@alignCast(self.slab[i * stride ..].ptr));
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

        fn main() callconv(.c) noreturn {
            const self = active;
            const i = self.current;
            self.entry(self, self.input);
            self.free[self.free_len] = i;
            self.free_len += 1;
            swap.InlineBr.swap(&self.sp[i], &self.scheduler);
            unreachable;
        }

        /// Runs `entry` now, up to its first `perform` or its end. Call this from
        /// outside the pool: a task that spawned could outgrow the rows behind it.
        pub fn spawn(self: *Self, entry: Entry, input: u64) error{PoolExhausted}!void {
            if (self.free_len == 0) return error.PoolExhausted;
            self.free_len -= 1;
            const i = self.free[self.free_len];
            const colour = @as(usize, i) % 128 * 128;
            const top = @intFromPtr(self.slab.ptr) + (@as(usize, i) + 1) * stride - colour;
            self.sp[i] = swap.fabricate(top, @intFromPtr(&main));
            self.entry = entry;
            self.input = input;
            self.current = i;
            active = self;
            swap.InlineBr.swap(&self.scheduler, &self.sp[i]);
        }

        /// Called by a handler, on the task's stack.
        pub fn perform(self: *Self, key: u64) error{Aborted}!u64 {
            const i = self.current;
            const n = self.len;
            self.values[n] = key;
            self.who[n] = i;
            self.len = n + 1;
            swap.InlineBr.swap(&self.sp[i], &self.scheduler);
            if (self.cancelled) return error.Aborted;
            return self.values[self.at];
        }

        fn resumeAll(self: *Self) void {
            active = self;
            const n = self.len;
            self.len = 0;
            for (self.who[0..n], 0..) |i, row| {
                self.at = @intCast(row);
                self.current = i;
                swap.InlineBr.swap(&self.scheduler, &self.sp[i]);
            }
        }

        /// Until every task ends: transform all rows, then resume each one.
        pub fn run(self: *Self, batch: Batch, ctx: *anyopaque) void {
            while (self.len != 0) {
                batch(ctx, self.values[0..self.len]);
                self.resumeAll();
            }
        }

        /// Every parked task gets error.Aborted, so `try` unwinds and `defer`s run.
        pub fn cancel(self: *Self) void {
            self.cancelled = true;
            while (self.len != 0) self.resumeAll();
            self.cancelled = false;
        }
    };
}
