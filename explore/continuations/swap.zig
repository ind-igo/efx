//! Stack switches for aarch64. Both save the same 20 registers on the outgoing
//! stack, so a frame made by `fabricate` starts a fiber under either one.
const std = @import("std");

pub const entry_frame = 0xa0;

/// The frame is filled by `ldp` on the way in, so it needs a fabricated resume
/// address at 0x58 and nothing else.
pub fn fabricate(top: usize, entry: usize) usize {
    const sp = top - entry_frame;
    const frame: [*]usize = @ptrFromInt(sp);
    @memset(frame[0 .. entry_frame / @sizeOf(usize)], 0);
    frame[0x58 / @sizeOf(usize)] = entry;
    return sp;
}

comptime {
    asm (
        \\.text
        \\.p2align 2
        \\.globl _sw_call_ret
        \\_sw_call_ret:
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
        \\
    );
}
extern fn sw_call_ret(from: *usize, to: *const usize) callconv(.c) void;

/// Everything the optimizer may assume survives a call does not survive here,
/// except what the asm saves itself.
/// `.lr`, not `.x30`: LLVM ignores a clobber spelled `x30`, keeps a live value in
/// the register across the switch, and the bug only shows in optimized builds.
const caller_saved: std.lang.assembly.Clobbers = .{
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
    .lr = true,
    .v0 = true,
    .v1 = true,
    .v2 = true,
    .v3 = true,
    .v4 = true,
    .v5 = true,
    .v6 = true,
    .v7 = true,
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
};

pub const CallRet = struct {
    pub const name = "call+ret";
    pub fn swap(from: *usize, to: *const usize) void {
        sw_call_ret(from, to);
    }
};

/// No `bl` and no `ret`: the return-address stack is left exactly as it was.
pub const InlineBr = struct {
    pub const name = "inline+br";
    pub inline fn swap(from: *usize, to: *const usize) void {
        var o0: usize = undefined;
        var o1: usize = undefined;
        asm volatile (
            \\sub sp, sp, #0xa0
            \\adr x9, 1f
            \\stp x19, x20, [sp, #0x00]
            \\stp x21, x22, [sp, #0x10]
            \\stp x23, x24, [sp, #0x20]
            \\stp x25, x26, [sp, #0x30]
            \\stp x27, x28, [sp, #0x40]
            \\stp x29, x9,  [sp, #0x50]
            \\stp d8,  d9,  [sp, #0x60]
            \\stp d10, d11, [sp, #0x70]
            \\stp d12, d13, [sp, #0x80]
            \\stp d14, d15, [sp, #0x90]
            \\mov x9, sp
            \\str x9, [x0]
            \\ldr x9, [x1]
            \\mov sp, x9
            \\ldp x19, x20, [sp, #0x00]
            \\ldp x21, x22, [sp, #0x10]
            \\ldp x23, x24, [sp, #0x20]
            \\ldp x25, x26, [sp, #0x30]
            \\ldp x27, x28, [sp, #0x40]
            \\ldp x29, x9,  [sp, #0x50]
            \\ldp d8,  d9,  [sp, #0x60]
            \\ldp d10, d11, [sp, #0x70]
            \\ldp d12, d13, [sp, #0x80]
            \\ldp d14, d15, [sp, #0x90]
            \\add sp, sp, #0xa0
            \\br x9
            \\1:
            : [o0] "={x0}" (o0),
              [o1] "={x1}" (o1),
            : [from] "{x0}" (from),
              [to] "{x1}" (to),
            : caller_saved);
    }
};
