//! The switch this project started with: a call into shared asm that ends in
//! `ret`. It mispredicts every time. Kept as the baseline for the benchmarks.
//! aarch64 only. It saves the same frame as `swap.InlineBr`.
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

pub const CallRet = struct {
    pub const name = "call+ret";
    pub fn swap(from: *usize, to: *const usize) void {
        sw_call_ret(from, to);
    }
};
