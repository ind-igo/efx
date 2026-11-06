//! A stack switch for aarch64 and x86_64.
const std = @import("std");
const builtin = @import("builtin");

const x86 = builtin.cpu.arch == .x86_64;

comptime {
    // Windows has more callee-saved registers and a stack limit in the TEB.
    const arch_ok = x86 or builtin.cpu.arch == .aarch64;
    if (!arch_ok or builtin.os.tag == .windows) @compileError("stack switching needs aarch64 or x86_64 on a non-Windows OS");
}

pub const entry_frame = if (x86) 56 + red_zone else 0xa0;
const red_zone = 128;

/// The frame is filled on the way in, so it needs a fabricated resume address
/// and nothing else.
pub fn fabricate(top: usize, entry: usize) usize {
    // x86_64 functions expect sp to be 8 past a 16-byte boundary on entry.
    const sp = (if (x86) top - 8 else top) - entry_frame;
    const frame: [*]usize = @ptrFromInt(sp);
    @memset(frame[0 .. entry_frame / @sizeOf(usize)], 0);
    frame[if (x86) 5 else 0x58 / @sizeOf(usize)] = entry;
    return sp;
}

/// Everything the optimizer may assume survives a call does not survive here,
/// except what the asm saves itself.
/// `.lr`, not `.x30`: LLVM ignores a clobber spelled `x30`, keeps a live value in
/// the register across the switch, and the bug only shows in optimized builds.
const aarch64_clobbers = blk: {
    @setEvalBranchQuota(100_000);
    var c: std.lang.assembly.Clobbers = .{ .memory = true, .nzcv = true, .lr = true };
    for (2..18) |i| @field(c, std.fmt.comptimePrint("x{d}", .{i})) = true;
    for (0..8) |i| @field(c, std.fmt.comptimePrint("v{d}", .{i})) = true;
    for (16..32) |i| @field(c, std.fmt.comptimePrint("v{d}", .{i})) = true;
    // Reserved by the platform on Darwin, an ordinary scratch register elsewhere.
    if (!builtin.os.tag.isDarwin()) c.x18 = true;
    break :blk c;
};

const x86_clobbers = blk: {
    @setEvalBranchQuota(100_000);
    var c: std.lang.assembly.Clobbers = .{
        .memory = true,
        .cc = true,
        .fpsr = true,
        .rax = true,
        .rcx = true,
        .rdx = true,
        .r8 = true,
        .r9 = true,
        .r10 = true,
        .r11 = true,
    };
    for (0..16) |i| @field(c, std.fmt.comptimePrint("xmm{d}", .{i})) = true;
    break :blk c;
};

/// No `bl` and no `ret`: the return-address stack is left exactly as it was.
pub const InlineBr = if (x86) X86 else Aarch64;

const Aarch64 = struct {
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
            : aarch64_clobbers);
    }
};

/// `jmp` instead of `ret`, for the same reason. Skips the red zone, because the
/// function holding this asm may be a leaf with locals below sp.
const X86 = struct {
    pub const name = "inline+jmp";
    pub inline fn swap(from: *usize, to: *const usize) void {
        var o0: usize = undefined;
        var o1: usize = undefined;
        asm volatile (
            \\leaq -128(%%rsp), %%rsp
            \\pushq %%rbp
            \\leaq 1f(%%rip), %%rax
            \\pushq %%rax
            \\pushq %%rbx
            \\pushq %%r12
            \\pushq %%r13
            \\pushq %%r14
            \\pushq %%r15
            \\movq %%rsp, (%%rdi)
            \\movq (%%rsi), %%rsp
            \\popq %%r15
            \\popq %%r14
            \\popq %%r13
            \\popq %%r12
            \\popq %%rbx
            \\popq %%rax
            \\popq %%rbp
            \\leaq 128(%%rsp), %%rsp
            \\jmpq *%%rax
            \\1:
            : [o0] "={rdi}" (o0),
              [o1] "={rsi}" (o1),
            : [from] "{rdi}" (from),
              [to] "{rsi}" (to),
            : x86_clobbers);
    }
};
