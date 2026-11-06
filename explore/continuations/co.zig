//! One-shot continuations on std.Io.fiber (OCaml 5 design), plus stack-copy multi-shot.
const std = @import("std");

// Opaque to the compiler: an ordinary external call as far as it can tell, so
// caller-saved registers are spilled normally. Everything callee-saved,
// including the link register, is saved here. aarch64 only.
const frame_size = 0xa0;
comptime {
    asm (
        \\.text
        \\.p2align 2
        \\.globl _efx_switch
        \\_efx_switch:
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
        \\  ret
    );
}
extern fn efx_switch(old: *Context, new: *Context) callconv(.c) void;
const Context = struct { sp: usize };

fn sw(old: *Context, new: *Context) void {
    efx_switch(old, new);
}

threadlocal var entering: ?*anyopaque = null;
const stack_size = 256 * 1024;
const red_zone = 256;

pub fn Co(comptime Req: type, comptime Resp: type, comptime R: type) type {
    return struct {
        const Self = @This();
        pub const Event = union(enum) { perform: Req, done: error{Aborted}!R };
        pub const Snapshot = struct { bytes: []u8, ctx: Context };

        stack: []align(16) u8,
        handler: Context = undefined,
        computation: Context = undefined,
        req: Req = undefined,
        resp: error{Aborted}!Resp = undefined,
        result: ?(error{Aborted}!R) = null,
        body: *const fn (*Self, *anyopaque) error{Aborted}!R,
        arg: *anyopaque,

        pub fn init(body: *const fn (*Self, *anyopaque) error{Aborted}!R, arg: *anyopaque) !Self {
            return .{
                .stack = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(16), stack_size),
                .body = body,
                .arg = arg,
            };
        }
        pub fn deinit(self: *Self) void {
            std.heap.page_allocator.free(self.stack);
        }

        fn entry() callconv(.c) noreturn {
            const self: *Self = @ptrCast(@alignCast(entering.?));
            self.result = self.body(self, self.arg);
            sw(&self.computation, &self.handler);
            unreachable;
        }

        fn event(self: *Self) Event {
            if (self.result) |r| return .{ .done = r };
            return .{ .perform = self.req };
        }

        /// Handler side: run until the first perform or completion.
        pub fn start(self: *Self) Event {
            // Fabricate the frame efx_switch restores: its `ret` lands on `entry`.
            const sp = @intFromPtr(self.stack.ptr) + self.stack.len - frame_size;
            const frame: [*]usize = @ptrFromInt(sp);
            @memset(frame[0 .. frame_size / @sizeOf(usize)], 0);
            frame[0x58 / @sizeOf(usize)] = @intFromPtr(&entry);
            self.computation = .{ .sp = sp };
            entering = self;
            sw(&self.handler, &self.computation);
            return self.event();
        }
        /// Handler side: `continue k v`. Returns when the computation next performs or ends.
        pub fn @"resume"(self: *Self, v: Resp) Event {
            self.resp = v;
            sw(&self.handler, &self.computation);
            return self.event();
        }
        /// Handler side: `discontinue k`. Unwinds through `try`, so `defer`s run.
        pub fn abort(self: *Self) Event {
            self.resp = error.Aborted;
            sw(&self.handler, &self.computation);
            return self.event();
        }
        /// Computation side.
        pub fn perform(self: *Self, req: Req) error{Aborted}!Resp {
            self.req = req;
            sw(&self.computation, &self.handler);
            return self.resp;
        }

        // ── Multi-shot: copy the live stack; restore at the same address ──
        pub fn snapshot(self: *Self, gpa: std.mem.Allocator) !Snapshot {
            const from = self.computation.sp - red_zone - @intFromPtr(self.stack.ptr);
            return .{ .bytes = try gpa.dupe(u8, self.stack[from..]), .ctx = self.computation };
        }
        pub fn restore(self: *Self, snap: Snapshot) void {
            const from = snap.ctx.sp - red_zone - @intFromPtr(self.stack.ptr);
            @memcpy(self.stack[from..], snap.bytes);
            self.computation = snap.ctx;
            self.result = null;
        }
    };
}
