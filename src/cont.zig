//! One-shot continuations in a fixed pool of stacks.
//!
//! A companion to efx that doesn't depend on it. A handler is a plain struct, so
//! a handler that parks is one that holds a pool:
//!
//!     pub fn get(self: *Store, key: u64) std.Io.Cancelable!u64 {
//!         return self.pool.perform(key);
//!     }
//!
//! The caller can't tell this from a handler that returns at once. Whoever owns
//! the pool drives it, and does its own I/O on its own stack:
//!
//!     while (pool.live() != 0) {
//!         pool.tick();
//!         const batch = pool.take();
//!         for (batch.requests, batch.conts) |request, k| try pool.complete(k, answer(request));
//!     }
//!
//! A pool belongs to one thread at a time. Scheduling and I/O are left to `std.Io`
//! or a runtime: another thread hands results to the driver, and the driver calls
//! `complete`. No allocation after `init`.
const std = @import("std");
const builtin = @import("builtin");

const Swap = @import("swap.zig").InlineBr;
const fabricate = @import("swap.zig").fabricate;

pub const Cancelable = std.Io.Cancelable;

/// A parked computation. Resuming advances `gen`, so a second resume is rejected
/// instead of corrupting a stack. 48 bits because a busy slot resumes many
/// millions of times a second, and a stale handle must not come back around.
pub const Cont = packed struct(u64) { index: u16, gen: u48 };

pub const Options = struct {
    Request: type = void,
    Reply: type = void,
    /// Each stack costs two kernel mappings for its guard page, and Linux allows
    /// about 65000 by default (`vm.max_map_count`).
    capacity: u16 = 1024,
    /// Rounded up to a page. Includes a guard page and up to 16 KiB of colouring.
    /// Stacks don't grow: running past the end faults on the guard page.
    stack_size: usize = 64 * 1024,
};

/// Page-aligned stacks all start on the same cache sets, and ASLR doesn't change
/// the low bits. Offsetting each top by a colour spreads them out.
const colours = 128;
const colour_step = 128;
/// How far ahead `tick` prefetches the frame it will resume.
const lookahead = 8;

pub fn Pool(comptime opts: Options) type {
    const capacity = opts.capacity;
    const stride = std.mem.alignForward(usize, opts.stack_size, std.heap.page_size_max);
    const nobody = std.math.maxInt(u16);
    if (capacity == 0 or capacity == nobody) @compileError("capacity must be between 1 and 65534");

    return struct {
        const Self = @This();
        pub const Request = opts.Request;
        pub const Reply = opts.Reply;

        /// Rows from one `tick`, in `perform` order. Valid until the next `tick`.
        pub const Batch = struct { requests: []const Request, conts: []const Cont };

        // Touched on every switch.
        sp: [capacity]usize,
        reply: [capacity]Reply,
        gen: [capacity]u48,
        canceled: [capacity]bool,

        // Touched at spawn and finish.
        free: [capacity]u16,
        free_len: u32,

        // Two sides, so a resume during `tick` lands in the next one.
        ready: [2][capacity]u16,
        ready_len: u32,
        side: u1,

        // `perform` appends one row.
        req: [capacity]Request,
        req_cont: [capacity]Cont,
        req_len: u32,

        running: u16,
        scheduler_sp: usize,
        slab: []align(std.heap.page_size_min) u8,

        /// In place, because the struct is large. Don't move it afterwards.
        pub fn init(self: *Self) error{ OutOfMemory, GuardPageFailed, StackTooSmall }!void {
            // A runtime check: page size varies among aarch64 Linux kernels.
            if (stride <= colours * colour_step + std.heap.pageSize()) return error.StackTooSmall;
            self.slab = try std.heap.page_allocator.alignedAlloc(
                u8,
                .fromByteUnits(std.heap.page_size_min),
                @as(usize, capacity) * stride,
            );
            errdefer std.heap.page_allocator.free(self.slab);
            self.gen = @splat(0);
            self.canceled = @splat(false);
            self.free_len = capacity;
            self.ready_len = 0;
            self.side = 0;
            self.req_len = 0;
            self.running = nobody;
            // LIFO, lowest index first: the stack finished last is reused next,
            // while it is still in cache.
            for (&self.free, 0..) |*f, i| f.* = @intCast(capacity - 1 - i);
            for (0..capacity) |i| {
                if (!protect(@alignCast(self.slab[i * stride ..].ptr), false)) return error.GuardPageFailed;
            }
        }

        /// Cancels whatever is still alive first, because a dropped stack never
        /// runs its `defer`s. Handlers those computations use must still exist,
        /// so end the pool before its handlers.
        pub fn deinit(self: *Self) void {
            self.cancelAll();
            for (0..capacity) |i| _ = protect(@alignCast(self.slab[i * stride ..].ptr), true);
            std.heap.page_allocator.free(self.slab);
        }

        fn protect(guard: [*]align(std.heap.page_size_min) u8, usable: bool) bool {
            const size = std.heap.pageSize();
            if (builtin.os.tag == .linux and !builtin.link_libc) {
                const prot: std.os.linux.PROT = if (usable) .{ .READ = true, .WRITE = true } else .{};
                return std.os.linux.errno(std.os.linux.mprotect(guard, size, prot)) == .SUCCESS;
            }
            const prot: std.c.PROT = if (usable) .{ .READ = true, .WRITE = true } else .{};
            return std.c.mprotect(guard, size, prot) == 0;
        }

        fn top(self: *const Self, comptime Args: type, i: usize) usize {
            const end = @intFromPtr(self.slab.ptr) + (i + 1) * stride - (i % colours) * colour_step;
            return std.mem.alignBackward(usize, end - @sizeOf(Args), @max(16, @alignOf(Args)));
        }

        fn Start(comptime func: anytype) type {
            const Fn = @TypeOf(func);
            const Args = std.meta.ArgsTuple(Fn);
            const Result = @typeInfo(Fn).@"fn".return_type.?;
            if (Result != void and Result != Cancelable!void)
                @compileError("a computation returns void or Cancelable!void; handle any other error inside it");
            return struct {
                // The first switch into a stack arrives here with `swap`'s
                // argument registers intact, so `from` is the scheduler's slot.
                // That gives the pool with no global, which matters because
                // pools of one type can run on different threads.
                fn run(from: *usize) callconv(.c) noreturn {
                    const self: *Self = @alignCast(@fieldParentPtr("scheduler_sp", from));
                    const i = self.running;
                    const args: *const Args = @ptrFromInt(self.top(Args, i));
                    if (Result == void) @call(.auto, func, args.*) else @call(.auto, func, args.*) catch {};
                    self.free[self.free_len] = i;
                    self.free_len += 1;
                    self.gen[i] +%= 1;
                    Swap.swap(&self.sp[i], &self.scheduler_sp);
                    unreachable;
                }
            };
        }

        /// Queue `func(args...)`. The arguments are copied to the top of its stack.
        pub fn spawn(
            self: *Self,
            comptime func: anytype,
            args: std.meta.ArgsTuple(@TypeOf(func)),
        ) error{PoolExhausted}!void {
            if (self.free_len == 0) return error.PoolExhausted;
            self.free_len -= 1;
            const i = self.free[self.free_len];
            const at = self.top(@TypeOf(args), i);
            @as(*@TypeOf(args), @ptrFromInt(at)).* = args;
            self.sp[i] = fabricate(at, @intFromPtr(&Start(func).run));
            self.enqueue(i);
        }

        /// Computations that have not finished, parked or not.
        pub fn live(self: *const Self) usize {
            return capacity - self.free_len;
        }

        /// The running computation, to keep and resume after it parks.
        pub fn continuation(self: *const Self) Cont {
            std.debug.assert(self.running != nobody);
            return .{ .index = self.running, .gen = self.gen[self.running] };
        }

        /// Stop here until `complete` or `cancel`.
        pub fn park(self: *Self) Cancelable!Reply {
            const i = self.running;
            std.debug.assert(i != nobody);
            Swap.swap(&self.sp[i], &self.scheduler_sp);
            if (self.canceled[i]) {
                self.canceled[i] = false;
                return error.Canceled;
            }
            return self.reply[i];
        }

        /// Append a row for the driver, then park.
        pub fn perform(self: *Self, request: Request) Cancelable!Reply {
            const n = self.req_len;
            self.req[n] = request;
            self.req_cont[n] = self.continuation();
            self.req_len = n + 1;
            return self.park();
        }

        /// One-shot resume, delivering `value`.
        pub fn complete(self: *Self, k: Cont, value: Reply) error{StaleContinuation}!void {
            try self.claim(k);
            self.reply[k.index] = value;
            self.enqueue(k.index);
        }

        /// One-shot resume with `error.Canceled`, so `try` unwinds and `defer`s run.
        pub fn cancel(self: *Self, k: Cont) error{StaleContinuation}!void {
            try self.claim(k);
            self.canceled[k.index] = true;
            self.enqueue(k.index);
        }

        /// Run every live computation to its end by cancelling it. Handles held
        /// elsewhere go stale. A `perform` during this cleanup gets
        /// `error.Canceled` too, so a `defer` can't wait on real work here.
        pub fn cancelAll(self: *Self) void {
            std.debug.assert(self.running == nobody);
            while (self.live() != 0) {
                while (self.ready_len != 0) self.tick();
                self.req_len = 0;
                var unused: [capacity]bool = @splat(false);
                for (self.free[0..self.free_len]) |i| unused[i] = true;
                for (unused, 0..) |skip, i| {
                    if (!skip) self.cancel(.{ .index = @intCast(i), .gen = self.gen[i] }) catch unreachable;
                }
            }
        }

        fn claim(self: *Self, k: Cont) error{StaleContinuation}!void {
            if (self.gen[k.index] != k.gen) return error.StaleContinuation;
            self.gen[k.index] +%= 1;
        }

        fn enqueue(self: *Self, i: u16) void {
            self.ready[self.side][self.ready_len] = i;
            self.ready_len += 1;
        }

        /// Run everything ready until it parks or ends.
        pub fn tick(self: *Self) void {
            const batch = self.ready[self.side][0..self.ready_len];
            self.side +%= 1;
            self.ready_len = 0;
            for (batch, 0..) |i, at| {
                if (at + lookahead < batch.len) {
                    const frame = self.sp[batch[at + lookahead]];
                    for (0..3) |line| @prefetch(@as([*]const u8, @ptrFromInt(frame + line * 64)), .{ .rw = .write });
                }
                self.running = i;
                Swap.swap(&self.scheduler_sp, &self.sp[i]);
            }
            self.running = nobody;
        }

        /// Take the rows appended so far.
        pub fn take(self: *Self) Batch {
            const n = self.req_len;
            self.req_len = 0;
            return .{ .requests = self.req[0..n], .conts = self.req_cont[0..n] };
        }
    };
}
