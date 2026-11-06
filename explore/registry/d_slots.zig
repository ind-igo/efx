//! efx dispatch cost, measured against direct calls, function pointers and
//! hand-written vtables.
//!
//!   * Function pointers, vtables and scopes reach the loops through a
//!     runtime-filled Ctx, and the loops are only called through a table, so
//!     LLVM cannot devirtualize them.
//!   * Every case runs the same handler body in the same loop shape.
//!   * On Apple cores a tight call loop's speed depends on the instruction count
//!     between calls: the `stp x29,x30`/`ldp x29,x30` frame save forms a
//!     store-to-load chain that costs 5 cycles per call at some loop lengths and
//!     2 at others. A single layout is a lottery, so each case is built at
//!     several NOP paddings (`Ks`) and reported as a distribution over them.
//!   * Runs repeat, cycle time is calibrated per round, and order is
//!     forward, reverse or shuffled.
//!
//! Output is CSV on stdout. bench/run.sh collects the runs and bench/analyze.py
//! aggregates them.
//!
//!   dispatch <fwd|rev|shuf> <seed> [mono|mixed|cold|vec|all|cold2] [rounds]
//!
//! `all` omits cold2, the slow L2-evicting walk. The cold groups read the
//! aarch64 counter directly, so they are empty on other architectures.
pub const efx_effects = .{ Eff(.tiny, 0), Eff(.rmw, 0), Eff(.mix, 0), Eff(.work, 0), Eff(.mix, 500), Eff(.mix, 600), Eff(.mix, 601), Eff(.mix, 602), Eff(.mix, 603), Eff(.mix, 604), Eff(.mix, 605), Eff(.mix, 606), Eff(.mix, 607), Eff(.mix, 608), Eff(.mix, 609), Eff(.mix, 610), Eff(.mix, 611), Eff(.mix, 612), Eff(.mix, 613), Eff(.mix, 614), Eff(.mix, 615), VecE, VecB };

const std = @import("std");
const builtin = @import("builtin");
const efx = @import("efx");

extern "c" fn pthread_set_qos_class_self_np(qos: c_uint, rel: c_int) c_int;

// ── Clock and cycle calibration ─────────────────────────────────────

var bench_io: std.Io = undefined;

inline fn now() i96 {
    return std.Io.Timestamp.now(bench_io, .awake).nanoseconds;
}

fn calibrateOnce() f64 {
    const reps: u64 = 200_000;
    const t0 = now();
    if (comptime builtin.cpu.arch == .aarch64) {
        var x: u64 = 0;
        var i: u64 = 0;
        var one: u64 = 1;
        std.mem.doNotOptimizeAway(&one);
        while (i < reps) : (i += 1) {
            x = asm (".rept 64\n add %[o], %[o], %[s]\n .endr\n"
                : [o] "=r" (-> u64),
                : [x] "0" (x),
                  [s] "r" (one),
            );
        }
        std.mem.doNotOptimizeAway(x);
    }
    const dt: f64 = @floatFromInt(now() - t0);
    return dt / (@as(f64, reps) * 64.0); // ns per cycle: dependent add chain, 1 per cycle
}

fn calibrate() f64 {
    if (comptime builtin.cpu.arch != .aarch64) return 0; // no dependent-add calibration here
    var best: f64 = 1e9;
    for (0..3) |_| best = @min(best, calibrateOnce());
    return best;
}

// ── Handler bodies ──────────────────────────────────────────────────
// Identical code in every case. `id` makes each handler's machine code distinct.

const Body = enum {
    /// One state load, one add. No store. Exposes raw call throughput.
    tiny,
    /// Load, add, store, as in the repo's handlers: serial memory dependency on `acc`.
    rmw,
    /// Read state, two multiplies. Small hash-like step. Calls overlap: no dependency between them.
    mix,
    /// Four mix rounds, with each call's input depending on the previous result (see MonoLoop).
    /// About 20 cycles of serial data dependency: handler work dominates the loop.
    work,
};

const State = extern struct { key: u64, acc: u64 };

inline fn body(comptime b: Body, id: u64, s: *State, v: u64) u64 {
    switch (b) {
        .tiny => return v +% s.key +% id,
        .rmw => {
            s.acc +%= v +% id;
            return s.acc;
        },
        .mix => {
            var x = (v ^ s.key ^ id) *% 0x9E3779B97F4A7C15;
            x ^= x >> 29;
            x *%= 0xBF58476D1CE4E5B9;
            return x ^ (x >> 32);
        },
        .work => {
            var x = v ^ s.key ^ id;
            for (0..4) |_| {
                x *%= 0x9E3779B97F4A7C15;
                x ^= x >> 29;
            }
            return x;
        },
    }
}

fn Handler(comptime b: Body, comptime id: u64) type {
    return struct {
        s: State = .{ .key = id *% 0x1234567 +% 1, .acc = 0 },
        pub fn op(self: *@This(), v: u64) u64 {
            return body(b, id, &self.s, v);
        }
    };
}

fn Eff(comptime b: Body, comptime id: u64) type {
    return efx.Effect(union(enum) {
        op: efx.Op(u64, u64),
        const tag_b = b;
        const tag_id = id;
    });
}

// ── Hand-written vtable, the std.mem.Allocator shape ────────────────

const VTable = struct { op: *const fn (*anyopaque, u64) u64 };
const Iface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    inline fn op(self: Iface, v: u64) u64 {
        return self.vtable.op(self.ptr, v);
    }
    fn of(h: anytype) Iface {
        const H = @typeInfo(@TypeOf(h)).pointer.child;
        const T = struct {
            fn call(p: *anyopaque, v: u64) u64 {
                const self: *H = @ptrCast(@alignCast(p));
                return self.op(v);
            }
            const vt: VTable = .{ .op = &call };
        };
        return .{ .ptr = h, .vtable = launder(*const VTable, &T.vt) };
    }
};

// ── Runtime laundering: hides provenance from the optimizer ─────────

fn launder(comptime T: type, v: T) T {
    var slot: T = v;
    return @as(*volatile T, &slot).*;
}

// ── Direct, non-inlined. Same body as the handlers ──────────────────

fn Direct(comptime b: Body) type {
    return struct {
        noinline fn op(s: *State, v: u64) u64 {
            return body(b, 0, s, v);
        }
    };
}

// ── Context reached only through a runtime pointer ──────────────────

const OpFn = *const fn (*State, u64) u64;

// ── Candidate layouts ───────────────────────────────────────────────
const TIdx = 2; // comptime-known position in a contract
const Flat = struct { state: *anyopaque, op: *const fn (*anyopaque, *const efx.Scope, u64) u64 };
inline fn execTyped(comptime E: type, comptime H: type, sc: *const [4]efx.Slot, v: u64) u64 {
    const VT = @TypeOf(E.makeVtable(H));
    const entry = sc[TIdx];
    const vt: VT = @ptrCast(@alignCast(entry.vtable));
    return vt.op(entry.state, @ptrCast(sc), v);
}
inline fn execFlat(sc: *const [4]Flat, v: u64) u64 {
    const e = sc[TIdx];
    return e.op(e.state, @ptrCast(sc), v);
}
fn StaticScope(comptime H: type) type {
    return struct { h: *H };
}
/// One call site, two scope kinds: comptime-known handlers inline fully.
inline fn execAny(sc: anytype, v: u64) u64 {
    return sc.h.op(v);
}

fn Ctx(comptime b: Body) type {
    return struct {
        const H = Handler(b, 0);
        h: H = .{},
        h_fp: H = .{},
        h_vt: H = .{},
        h_ef: H = .{},
        h_ty: H = .{},
        h_fl: H = .{},
        typed: [4]efx.Slot = undefined,
        flat: [4]Flat = undefined,
        st: State = .{ .key = 1, .acc = 0 },
        st_fp: State = .{ .key = 1, .acc = 0 },
        fnp: OpFn = undefined,
        iface: Iface = undefined,
        scope: efx.Scope = undefined,
    };
}

// ── Monomorphic cases ───────────────────────────────────────────────

const Case = enum {
    empty, // loop and sink only, no handler work
    inline_body, // handler body written into the loop: the "abstraction gone" floor
    comptime_generic, // H as comptime parameter, h.op(v). The optimizer may inline
    direct, // noinline fn
    fn_pointer, // runtime-chosen *const fn
    hand_vtable, // Iface{ptr, vtable}, the std.mem.Allocator shape
    effect, // Effect.exec, unmodified
    effect_plain_slot, // diagnostic: exec with a non-atomic slot load, null checks kept
    effect_unchecked, // diagnostic: non-atomic slot load, no checks
    typed, // comptime index, vtable pointer, no checks
    flat, // comptime index, fn pointer stored in the scope
    static_scope, // handler type known at comptime
};

inline fn pad(comptime k: u32) void {
    if (k > 0) asm volatile (".rept " ++ std.fmt.comptimePrint("{d}", .{k}) ++ "\n nop\n .endr\n");
}

inline fn generic(comptime H: type, h: *H, v: anytype) @TypeOf(v) {
    return h.op(v);
}

/// A copy of efx's exec with the two parts varied that are specific to it: the atomic slot load
/// and the unbound-handler checks. Only used to attribute cost. The library is unchanged.
inline fn execVariant(comptime E: type, comptime H: type, comptime check: bool, sc: *const efx.Scope, v: u64) u64 {
    if (@hasDecl(@import("root"), "efx_columns")) return E.exec(sc, .op, v);
    const VT = @TypeOf(E.makeVtable(H));
    const s = E.slot;
    if (check) {
        if (s == std.math.maxInt(usize)) @panic("unbound");
        const entry = sc._slots[s];
        const vt: VT = @ptrCast(@alignCast(entry.vtable));
        return vt.op(entry.state, sc, v);
    } else {
        const entry = sc._slots[s];
        const vt: VT = @ptrCast(@alignCast(entry.vtable));
        return vt.op(entry.state, sc, v);
    }
}

fn MonoLoop(comptime case: Case, comptime b: Body, comptime k: u32) type {
    return struct {
        noinline fn run(ctx_any: *anyopaque, n: u64) u64 {
            const C = Ctx(b);
            const ctx: *C = @ptrCast(@alignCast(ctx_any));
            const E = Eff(b, 0);
            const fnp = ctx.fnp;
            const iface = ctx.iface;
            const sc = &ctx.scope;
            var sink: u64 = 0;
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                pad(k);
                const v: u64 = if (b == .work) i ^ sink else i;
                const r: u64 = switch (case) {
                    .empty => v,
                    .inline_body => body(b, 0, &ctx.st, v),
                    .comptime_generic => generic(C.H, &ctx.h, v),
                    .direct => Direct(b).op(&ctx.st_fp, v),
                    .fn_pointer => fnp(&ctx.st_fp, v),
                    .hand_vtable => iface.op(v),
                    .effect => E.exec(sc, .op, v),
                    .effect_plain_slot => execVariant(E, C.H, true, sc, v),
                    .effect_unchecked => execVariant(E, C.H, false, sc, v),
                    .typed => execTyped(E, C.H, &ctx.typed, v),
                    .flat => execFlat(&ctx.flat, v),
                    .static_scope => execAny(&StaticScope(C.H){ .h = &ctx.h }, v),
                };
                sink +%= r;
                std.mem.doNotOptimizeAway(sink);
            }
            return sink;
        }
    };
}

// ── Mixed workload: targets chosen at runtime ───────────────────────

const MIX_N = 16; // handlers available
const SEQ_LEN: usize = 1 << 20;

const MixCase = enum {
    no_dispatch, // handler body inlined, per-target data looked up, no indirect branch
    fn_table, // fns[t](&states[t], v)
    vtable_array, // ifaces[t].op(v)
    effect_scopes, // one Effect, array of scopes binding different handlers, one call site
    effect_switch, // N different Effects in one scope, switch on t, N call sites
    closed_switch, // switch over N comptime-known handlers, bodies inlined (the monomorphized fair rival)
};

const MixB: Body = .mix;

fn MixH(comptime id: u64) type {
    return Handler(MixB, 1000 + id);
}

const MixCtx = struct {
    hs: HandlerTuple = undefined,
    states: [MIX_N]State = undefined,
    ids: [MIX_N]u64 = undefined,
    fns: [MIX_N]OpFn = undefined,
    ifaces: [MIX_N]Iface = undefined,
    scopes: [MIX_N]efx.Scope = undefined,
    one_scope: efx.Scope = .{},

    const HandlerTuple = blk: {
        var fields: [MIX_N]type = undefined;
        for (0..MIX_N) |j| fields[j] = MixH(j);
        break :blk @Tuple(&fields);
    };
};

fn fnTableEntry(comptime id: u64) OpFn {
    return &struct {
        fn f(s: *State, v: u64) u64 {
            return body(MixB, 1000 + id, s, v);
        }
    }.f;
}

fn MixLoop(comptime case: MixCase, comptime k: u32) type {
    return struct {
        noinline fn run(ctx: *MixCtx, seq: [*]const u8, n: u64) u64 {
            var sink: u64 = 0;
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                const t: usize = seq[i & (SEQ_LEN - 1)];
                pad(k);
                const r: u64 = switch (case) {
                    .no_dispatch => body(MixB, ctx.ids[t], &ctx.states[t], i),
                    .fn_table => ctx.fns[t](&ctx.states[t], i),
                    .vtable_array => ctx.ifaces[t].op(i),
                    .effect_scopes => Eff(MixB, 500).exec(&ctx.scopes[t], .op, i),
                    .effect_switch => sw: switch (@as(u4, @intCast(t))) {
                        inline else => |j| break :sw Eff(MixB, 600 + @as(u64, j)).exec(&ctx.one_scope, .op, i),
                    },
                    .closed_switch => sw: switch (@as(u4, @intCast(t))) {
                        inline else => |j| break :sw ctx.hs[j].op(i),
                    },
                };
                sink +%= r;
                std.mem.doNotOptimizeAway(sink);
            }
            return sink;
        }
    };
}

const Pattern = enum { rr, rand };

fn fillSeq(seq: []u8, targets: u8, pattern: Pattern, seed: u64, period: usize) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    for (seq, 0..) |*s, i| {
        s.* = switch (pattern) {
            .rr => @intCast(i % targets),
            .rand => if (i < period) r.uintLessThan(u8, targets) else seq[i - period],
        };
    }
}

// ── Cold path: data caches evicted between calls ───────────────────
// The call alone is bracketed by serialising counter reads, because a walk's own noise is far
// larger than a few extra misses. The counter ticks at 24 MHz; the mean over many samples still
// resolves below a tick because the walk's length varies relative to the tick phase.
// Each object sits on its own page so one load cannot prefetch or share a line with another, and
// the fn pointer and iface are read from memory, as a caller holding `self` must do.

const ColdCase = enum { timer_only, direct, fn_pointer, hand_vtable, effect, effect_unchecked, typed, flat };

const ColdH = Handler(.tiny, 0);
const ColdCtx = struct {
    st: State align(4096) = .{ .key = 1, .acc = 0 },
    h_vt: ColdH align(4096) = .{},
    h_ef: ColdH align(4096) = .{},
    fnp: OpFn align(4096) = undefined,
    iface: Iface align(4096) = undefined,
    scope: efx.Scope align(4096) = undefined,
    h_ty: ColdH align(4096) = .{},
    h_fl: ColdH align(4096) = .{},
    h_un: ColdH align(4096) = .{},
    typed: [4]efx.Slot align(4096) = undefined,
    flat: [4]Flat align(4096) = undefined,
    scope_un: efx.Scope align(4096) = undefined,
};

const EVICT_STRIDE = 64;
var cold_ns: f64 = 0;

inline fn ticks() u64 {
    return asm volatile ("isb\n mrs %[t], cntvct_el0\n isb"
        : [t] "=r" (-> u64),
    );
}

fn ColdLoop(comptime case: ColdCase, comptime evict: usize) type {
    return struct {
        noinline fn run(ctx: *ColdCtx, buf: [*]const u8, n: u64) u64 {
            const E = Eff(.tiny, 0);
            const sc = &ctx.scope;
            var sink: u64 = 0;
            var total: u64 = 0;
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                var off: usize = 0;
                while (off < evict) : (off += EVICT_STRIDE) sink +%= buf[off];
                std.mem.doNotOptimizeAway(sink);
                const t0 = ticks();
                const r: u64 = switch (case) {
                    .timer_only => i,
                    .direct => Direct(.tiny).op(&ctx.st, i),
                    .fn_pointer => launder_load(OpFn, &ctx.fnp)(&ctx.st, i),
                    .hand_vtable => launder_load(Iface, &ctx.iface).op(i),
                    .effect => E.exec(sc, .op, i),
                    .effect_unchecked => execVariant(E, ColdH, false, &ctx.scope_un, i),
                    .typed => execTyped(E, ColdH, &ctx.typed, i),
                    .flat => execFlat(&ctx.flat, i),
                };
                total += ticks() - t0;
                sink +%= r;
            }
            const freq = asm volatile ("mrs %[f], cntfrq_el0"
                : [f] "=r" (-> u64),
            );
            cold_ns = @as(f64, @floatFromInt(total)) * 1e9 / @as(f64, @floatFromInt(freq));
            return sink;
        }
    };
}

/// A plain load the optimizer cannot move out of the timed region.
inline fn launder_load(comptime T: type, p: *T) T {
    return @as(*volatile T, p).*;
}

// ── Vectorization: what inlining buys ───────────────────────────────

const VecCase = enum { comptime_generic, direct, hand_vtable, effect, static_scope, batch_1, batch_8, batch_64, batch_4096 };

const VecH = struct {
    m: u32 = 3,
    pub fn op(self: *VecH, v: u32) u32 {
        return v *% self.m;
    }
    noinline fn opDirect(self: *VecH, v: u32) u32 {
        return v *% self.m;
    }
};
const VecE = efx.Effect(union(enum) { op: efx.Op(u32, u32) });
const VecB = efx.Effect(union(enum) { sum: efx.Op([]const u32, u32) });
const VecBH = struct {
    m: u32 = 3,
    pub fn sum(self: *VecBH, xs: []const u32) u32 {
        var s: u32 = 0;
        for (xs) |x| s +%= x *% self.m;
        return s;
    }
};
const VecVT = struct { op: *const fn (*anyopaque, u32) u32 };
const VecCtx = struct {
    h: VecH = .{},
    p: *anyopaque = undefined,
    vt: *const VecVT = undefined,
    scope: efx.Scope = undefined,
    bh: VecBH = .{},
    bscope: efx.Scope = undefined,
};

fn VecLoop(comptime case: VecCase) type {
    return struct {
        noinline fn run(ctx: *VecCtx, a: []const u32, n: u64) u64 {
            var sink: u32 = 0;
            var rep: u64 = 0;
            while (rep < n) : (rep += 1) {
                const block: usize = switch (case) {
                    .batch_1 => 1,
                    .batch_8 => 8,
                    .batch_64 => 64,
                    .batch_4096 => 4096,
                    else => 0,
                };
                if (block != 0) {
                    var off: usize = 0;
                    while (off < a.len) : (off += block) {
                        sink +%= VecB.exec(&ctx.bscope, .sum, a[off..@min(off + block, a.len)]);
                    }
                    std.mem.doNotOptimizeAway(sink);
                    continue;
                }
                for (a) |x| {
                    sink +%= switch (case) {
                        .static_scope => ctx.h.op(x),
                        .batch_1, .batch_8, .batch_64, .batch_4096 => unreachable,
                        .comptime_generic => generic(VecH, &ctx.h, x),
                        .direct => ctx.h.opDirect(x),
                        .hand_vtable => ctx.vt.op(ctx.p, x),
                        .effect => VecE.exec(&ctx.scope, .op, x),
                    };
                }
                std.mem.doNotOptimizeAway(sink);
            }
            return sink;
        }
    };
}

// ── Case table ──────────────────────────────────────────────────────

const Ks = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
const MixKs = [_]u32{ 0, 8 };
const MONO_N: u64 = 5_000_000;
const MIX_ITERS: u64 = 4_000_000;
const COLD_WARM_ITERS: u64 = 500_000;
const COLD_L1_ITERS: u64 = 30_000;
const COLD_L2_ITERS: u64 = 2_500;
const EVICT_L1 = 512 * 1024; // L1D is 128 KiB on this core
const EVICT_L2 = 32 * 1024 * 1024; // L2 is 16 MiB
const VEC_LEN = 4096;
const VEC_REPS: u64 = 4_000;

const Item = struct {
    group: []const u8,
    case: []const u8,
    body: []const u8,
    k: u32,
    targets: u32 = 0,
    pattern: []const u8 = "",
    iters: u64,
    ops: u64,
    run: *const fn (*Env, u64) u64,
    self_timed: bool = false,
};

const Env = struct {
    cTiny: *Ctx(.tiny),
    cRmw: *Ctx(.rmw),
    cMix: *Ctx(.mix),
    cWork: *Ctx(.work),
    mix: *MixCtx,
    seqs: *[seq_kinds]([]u8),
    buf: [*]u8,
    cold: *ColdCtx,
    vec: *VecCtx,
    arr: []u32,
};

const seq_targets = [_]u8{ 1, 2, 4, 16 };
const seq_periods = [_]usize{ SEQ_LEN, 4096, 64 }; // rand with a shorter period: can the predictor learn it?
const seq_kinds = seq_targets.len * 2 + seq_periods.len - 1;

fn seqIndex(ti: usize, pattern: Pattern) usize {
    return ti * 2 + @backingInt(pattern);
}

fn items(comptime want: []const u8) []const Item {
    comptime {
        @setEvalBranchQuota(10_000_000);
        var list: [4000]Item = undefined;
        var n: usize = 0;
        const all = std.mem.eql(u8, want, "all");
        if (all or std.mem.eql(u8, want, "mono")) {
            for (std.enums.values(Body)) |b| for (std.enums.values(Case)) |c| for (Ks) |k| {
                const L = MonoLoop(c, b, k);
                const R = struct {
                    fn go(e: *Env, it: u64) u64 {
                        const ctx: *anyopaque = switch (b) {
                            .tiny => e.cTiny,
                            .rmw => e.cRmw,
                            .mix => e.cMix,
                            .work => e.cWork,
                        };
                        return L.run(ctx, it);
                    }
                };
                list[n] = .{ .group = "mono", .case = @tagName(c), .body = @tagName(b), .k = k, .iters = MONO_N, .ops = MONO_N, .run = R.go };
                n += 1;
            };
        }
        if (all or std.mem.eql(u8, want, "mixed")) {
            for (std.enums.values(MixCase)) |c| for (MixKs) |k| for (seq_targets, 0..) |t, ti| for (std.enums.values(Pattern)) |p| {
                if (t == 1 and p == .rand) continue;
                const L = MixLoop(c, k);
                const idx = seqIndex(ti, p);
                const R = struct {
                    fn go(e: *Env, it: u64) u64 {
                        return L.run(e.mix, e.seqs[idx].ptr, it);
                    }
                };
                list[n] = .{ .group = "mixed", .case = @tagName(c), .body = "mix", .k = k, .targets = t, .pattern = @tagName(p), .iters = MIX_ITERS, .ops = MIX_ITERS, .run = R.go };
                n += 1;
            };
            // Period check: 16 random targets repeating every `seq_periods` entries.
            for ([_]MixCase{ .fn_table, .effect_scopes }) |c| for (seq_periods[1..], 1..) |per, pi| {
                const L = MixLoop(c, 0);
                const idx = seq_targets.len * 2 + pi - 1;
                const R = struct {
                    fn go(e: *Env, it: u64) u64 {
                        return L.run(e.mix, e.seqs[idx].ptr, it);
                    }
                };
                list[n] = .{ .group = "period", .case = @tagName(c), .body = "mix", .k = 0, .targets = @intCast(per), .pattern = "rand", .iters = MIX_ITERS, .ops = MIX_ITERS, .run = R.go };
                n += 1;
            };
        }
        const cold_supported = builtin.cpu.arch == .aarch64;
        if (cold_supported and (all or std.mem.eql(u8, want, "cold"))) {
            for ([_]usize{ 0, EVICT_L1 }, [_][]const u8{ "warm", "l1_evicted" }, [_]u64{ COLD_WARM_ITERS, COLD_L1_ITERS }) |ev, lab, its| {
                for (std.enums.values(ColdCase)) |c| {
                    const L = ColdLoop(c, ev);
                    const R = struct {
                        fn go(e: *Env, it: u64) u64 {
                            return L.run(e.cold, e.buf, it);
                        }
                    };
                    list[n] = .{ .group = "cold", .case = @tagName(c), .body = lab, .k = 0, .iters = its, .ops = its, .run = R.go, .self_timed = true };
                    n += 1;
                }
            }
        }
        if (cold_supported and std.mem.eql(u8, want, "cold2")) {
            for (std.enums.values(ColdCase)) |c| {
                const L = ColdLoop(c, EVICT_L2);
                const R = struct {
                    fn go(e: *Env, it: u64) u64 {
                        return L.run(e.cold, e.buf, it);
                    }
                };
                list[n] = .{ .group = "cold", .case = @tagName(c), .body = "l2_evicted", .k = 0, .iters = COLD_L2_ITERS, .ops = COLD_L2_ITERS, .run = R.go, .self_timed = true };
                n += 1;
            }
        }
        if (all or std.mem.eql(u8, want, "vec")) {
            for (std.enums.values(VecCase)) |c| {
                const L = VecLoop(c);
                const R = struct {
                    fn go(e: *Env, it: u64) u64 {
                        return L.run(e.vec, e.arr, it);
                    }
                };
                list[n] = .{ .group = "vec", .case = @tagName(c), .body = "mul", .k = 0, .iters = VEC_REPS, .ops = VEC_REPS * VEC_LEN, .run = R.go };
                n += 1;
            }
        }
        const out = list[0..n].*;
        const final = out;
        return &final;
    }
}

const item_table = struct {
    const mono = items("mono");
    const mixed = items("mixed");
    const cold = items("cold");
    const cold2 = items("cold2");
    const vec = items("vec");
};

fn setupCtx(comptime b: Body, ctx: *Ctx(b)) void {
    ctx.fnp = launder(OpFn, &Direct(b).op);
    ctx.iface = Iface.of(&ctx.h_vt);
    ctx.scope = launder(efx.Scope, efx.Scope.init(.{.{ Eff(b, 0), &ctx.h_ef }}));
    {
        const VH = Ctx(b).H;
        const vt = Eff(b, 0).makeVtable(VH);
        ctx.typed = undefined;
        ctx.typed[TIdx] = .{ .state = launder(*anyopaque, &ctx.h_ty), .vtable = launder(*const anyopaque, @ptrCast(vt)) };
        ctx.flat[TIdx] = .{ .state = launder(*anyopaque, &ctx.h_fl), .op = launder(*const fn (*anyopaque, *const efx.Scope, u64) u64, vt.op) };
    }
}

fn sequence(ctx: *MixCtx) void {
    inline for (0..MIX_N) |j| {
        ctx.hs[j] = .{};
        ctx.ids[j] = launder(u64, 1000 + j);
        ctx.states[j] = launder(State, ctx.hs[j].s);
        ctx.fns[j] = launder(OpFn, fnTableEntry(j));
        ctx.ifaces[j] = Iface.of(&ctx.hs[j]);
        ctx.scopes[j] = efx.Scope.init(.{.{ Eff(MixB, 500), &ctx.hs[j] }});
        ctx.one_scope = ctx.one_scope.bind(Eff(MixB, 600 + j), &ctx.hs[j]);
    }
}

pub fn main(init: std.process.Init) !void {
    bench_io = init.io;
    if (comptime builtin.os.tag.isDarwin()) {
        _ = pthread_set_qos_class_self_np(0x21, 0); // USER_INTERACTIVE: prefer P-cores
    }
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    _ = args.next();
    const mode = args.next() orelse "shuf";
    const seed = try std.fmt.parseInt(u64, args.next() orelse "1", 10);
    const which = args.next() orelse "all";
    const rounds = try std.fmt.parseInt(usize, args.next() orelse "5", 10);

    // Heap, with distinct allocations, so nothing is a link-time constant.
    const cTiny = try gpa.create(Ctx(.tiny));
    cTiny.* = .{};
    const cRmw = try gpa.create(Ctx(.rmw));
    cRmw.* = .{};
    const cMix = try gpa.create(Ctx(.mix));
    cMix.* = .{};
    setupCtx(.tiny, cTiny);
    setupCtx(.rmw, cRmw);
    setupCtx(.mix, cMix);
    const cWork = try gpa.create(Ctx(.work));
    cWork.* = .{};
    setupCtx(.work, cWork);

    const mix = try gpa.create(MixCtx);
    mix.* = .{};
    sequence(mix);

    var seqs: [seq_kinds][]u8 = undefined;
    for (seq_targets, 0..) |t, ti| for (std.enums.values(Pattern)) |p| {
        const s = try gpa.alloc(u8, SEQ_LEN);
        fillSeq(s, t, p, seed *% 31 +% ti, SEQ_LEN);
        seqs[seqIndex(ti, p)] = s;
    };
    for (seq_periods[1..], 1..) |per, pi| {
        const s = try gpa.alloc(u8, SEQ_LEN);
        fillSeq(s, 16, .rand, seed *% 37 +% pi, per);
        seqs[seq_targets.len * 2 + pi - 1] = s;
    }

    const buf = try gpa.alloc(u8, EVICT_L2);
    @memset(buf, 1);
    const cold = try gpa.create(ColdCtx);
    cold.* = .{};
    cold.fnp = launder(OpFn, &Direct(.tiny).op);
    cold.iface = Iface.of(&cold.h_vt);
    cold.scope = efx.Scope.init(.{.{ Eff(.tiny, 0), &cold.h_ef }});
    cold.scope_un = efx.Scope.init(.{.{ Eff(.tiny, 0), &cold.h_un }});
    {
        const vt = Eff(.tiny, 0).makeVtable(ColdH);
        cold.typed = undefined;
        cold.typed[TIdx] = .{ .state = launder(*anyopaque, &cold.h_ty), .vtable = launder(*const anyopaque, @ptrCast(vt)) };
        cold.flat[TIdx] = .{ .state = launder(*anyopaque, &cold.h_fl), .op = launder(*const fn (*anyopaque, *const efx.Scope, u64) u64, vt.op) };
    }
    const vec = try gpa.create(VecCtx);
    vec.* = .{};
    vec.p = launder(*anyopaque, &vec.h);
    const vectable = struct {
        fn call(p: *anyopaque, v: u32) u32 {
            const self: *VecH = @ptrCast(@alignCast(p));
            return self.op(v);
        }
        const vt: VecVT = .{ .op = &call };
    };
    vec.vt = launder(*const VecVT, &vectable.vt);
    vec.scope = efx.Scope.init(.{.{ VecE, &vec.h }});
    vec.bscope = efx.Scope.init(.{.{ VecB, &vec.bh }});
    const arr = try gpa.alloc(u32, VEC_LEN);
    for (arr, 0..) |*x, i| x.* = launder(u32, @intCast(i));

    var env: Env = .{ .cTiny = cTiny, .cRmw = cRmw, .cMix = cMix, .cWork = cWork, .mix = mix, .seqs = &seqs, .buf = buf.ptr, .cold = cold, .vec = vec, .arr = arr };

    var list: std.ArrayList(Item) = .empty;
    if (std.mem.eql(u8, which, "all") or std.mem.eql(u8, which, "mono")) try list.appendSlice(gpa, item_table.mono);
    if (std.mem.eql(u8, which, "all") or std.mem.eql(u8, which, "mixed")) try list.appendSlice(gpa, item_table.mixed);
    if (std.mem.eql(u8, which, "all") or std.mem.eql(u8, which, "cold")) try list.appendSlice(gpa, item_table.cold);
    if (std.mem.eql(u8, which, "all") or std.mem.eql(u8, which, "vec")) try list.appendSlice(gpa, item_table.vec);
    if (std.mem.eql(u8, which, "cold2")) try list.appendSlice(gpa, item_table.cold2);

    const order = try gpa.alloc(usize, list.items.len);
    var rng = std.Random.DefaultPrng.init(seed);

    var stdout_buf: [64 * 1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const out = &w.interface;
    try out.print("group,case,body,k,targets,pattern,round,pos,ns,ns_per_cycle\n", .{});

    var sink: u64 = 0;
    for (0..rounds) |round| {
        for (order, 0..) |*o, i| o.* = i;
        if (std.mem.eql(u8, mode, "rev")) {
            std.mem.reverse(usize, order);
        } else if (std.mem.eql(u8, mode, "shuf")) {
            rng.random().shuffle(usize, order);
        }
        const cal = calibrate();
        for (order, 0..) |idx, pos| {
            const it = list.items[idx];
            sink +%= it.run(&env, it.iters / 5); // warm-up: predictors and caches primed for this case
            const t0 = now();
            sink +%= it.run(&env, it.iters);
            const wall: f64 = @floatFromInt(now() - t0);
            const dt = if (it.self_timed) cold_ns else wall;
            try out.print("{s},{s},{s},{d},{d},{s},{d},{d},{d:.4},{d:.5}\n", .{
                it.group, it.case, it.body, it.k, it.targets, it.pattern, round, pos, dt / @as(f64, @floatFromInt(it.ops)), cal,
            });
        }
        try out.flush();
    }
    std.mem.doNotOptimizeAway(sink);
}
