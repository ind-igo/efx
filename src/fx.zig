const std = @import("std");
const testing = std.testing;
const root = @import("root");

// ── Configuration ─────────────────────────────────────────────────────

pub const MAX_EFFECTS: usize = if (@hasDecl(root, "libfx_max_effects"))
    root.libfx_max_effects
else
    16;

// ── Constants ─────────────────────────────────────────────────────────

const UNASSIGNED = std.math.maxInt(usize);

var next_slot: usize = 0;

pub const Slot = struct {
    state: *anyopaque = undefined,
    vtable: ?*const anyopaque = null,
};

// ── Op — operation signature marker ───────────────────────────────────

/// Operation signature: `Op(ArgType, ReturnType)`.
/// Use as a union variant payload inside the union passed to `Effect()`.
///
///   fx.Op([]const u8, void)         — void-returning operation
///   fx.Op([]const u8, ?[]const u8)  — operation with a return type
pub fn Op(comptime Arg: type, comptime Result: type) type {
    return struct {
        pub const ArgType = Arg;
        pub const ResultType = Result;
        // Non-zero-size field so Op can be used as a union variant payload.
        _phantom: u0 = 0,
    };
}

fn isOpType(comptime T: type) bool {
    return @hasDecl(T, "ArgType") and @hasDecl(T, "ResultType");
}

// ── Effect — dispatchable effect type from a tagged union ─────────────

pub fn Effect(comptime U: type) type {
    const union_info = @typeInfo(U).@"union";
    const fields = union_info.fields;

    const Vtable = comptime blk: {
        var field_names: [fields.len][:0]const u8 = undefined;
        var field_types: [fields.len]type = undefined;
        for (fields, 0..) |field, i| {
            const OpType = field.type;
            if (!isOpType(OpType))
                @compileError("Effect union variant '" ++ field.name ++ "' must have an Op(...) payload");
            field_names[i] = field.name;
            field_types[i] = *const fn (*anyopaque, *const Scope, OpType.ArgType) OpType.ResultType;
        }
        break :blk @Struct(.auto, null, &field_names, &field_types, &@splat(.{}));
    };

    return struct {
        const Self = @This();

        pub const Union = U;
        pub var slot: usize = UNASSIGNED;

        /// Assign a slot index for this effect, or return the existing one.
        /// Thread-safe: uses CAS to ensure exactly one assignment.
        /// Note: if two threads race on first use of the same effect, the loser's
        /// `next_slot` increment is wasted (one slot leaked). This is benign —
        /// it only happens once per effect, only under concurrent first-use,
        /// and typical usage initializes effects on a single thread at startup.
        pub fn ensureSlot() usize {
            const current = @atomicLoad(usize, &slot, .acquire);
            if (current != UNASSIGNED) return current;

            const new_slot = @atomicRmw(usize, &next_slot, .Add, 1, .acq_rel);
            if (new_slot >= MAX_EFFECTS) @panic("too many effects");

            return @cmpxchgStrong(usize, &slot, UNASSIGNED, new_slot, .acq_rel, .acquire) orelse new_slot;
        }

        pub fn makeVtable(comptime H: type) *const Vtable {
            const vtable = comptime blk: {
                var vt: Vtable = undefined;
                for (fields) |field| {
                    const OpType = field.type;
                    if (!@hasDecl(H, field.name)) {
                        @compileError("Handler '" ++ @typeName(H) ++ "' is missing method '" ++ field.name ++ "'");
                    }
                    const method = @field(H, field.name);
                    const MethodInfo = @typeInfo(@TypeOf(method)).@"fn";
                    const has_arg = OpType.ArgType != void;
                    const base_params: usize = if (has_arg) 2 else 1;

                    const wants_scope = if (MethodInfo.params.len == base_params + 1) true
                        else if (MethodInfo.params.len == base_params) false
                        else @compileError("Handler method '" ++ field.name ++ "' on '" ++ @typeName(H) ++ "' has wrong number of parameters");

                    if (MethodInfo.return_type != OpType.ResultType) {
                        @compileError("Handler method '" ++ field.name ++ "' on '" ++ @typeName(H) ++ "' has wrong return type");
                    }

                    const trampoline = struct {
                        fn call(opaque_ptr: *anyopaque, sc: *const Scope, arg: OpType.ArgType) OpType.ResultType {
                            const self: *H = @ptrCast(@alignCast(opaque_ptr));
                            if (wants_scope) {
                                if (has_arg) return @field(H, field.name)(self, sc, arg)
                                else return @field(H, field.name)(self, sc);
                            } else {
                                if (has_arg) return @field(H, field.name)(self, arg)
                                else return @field(H, field.name)(self);
                            }
                        }
                    };
                    @field(vt, field.name) = &trampoline.call;
                }
                break :blk vt;
            };
            const static = struct {
                const v: Vtable = vtable;
            };
            return &static.v;
        }

        pub fn exec(
            sc: *const Scope,
            comptime op: std.meta.FieldEnum(U),
            arg: fields[@intFromEnum(op)].type.ArgType,
        ) fields[@intFromEnum(op)].type.ResultType {
            const s = @atomicLoad(usize, &slot, .acquire);
            if (s == UNASSIGNED) @panic("libfx: effect was never bound in any scope: " ++ @typeName(U));
            const entry = sc._slots[s];
            const opaque_vt = entry.vtable orelse @panic("libfx: no handler bound in this scope for " ++ @typeName(U));
            const vt: *const Vtable = @ptrCast(@alignCast(opaque_vt));
            const trampoline = @field(vt.*, fields[@intFromEnum(op)].name);
            return trampoline(entry.state, sc, arg);
        }
    };
}

// ── Scope — explicit effect scope ─────────────────────────────────────

pub const Scope = struct {
    _slots: [MAX_EFFECTS]Slot = @splat(Slot{}),

    pub fn init(pairs: anytype) Scope {
        var self = Scope{};
        inline for (pairs) |pair| {
            const E = pair[0];
            const H = HandlerType(@TypeOf(pair[1]));
            const s = E.ensureSlot();
            const vt = comptime E.makeVtable(H);
            self._slots[s] = .{ .state = @ptrCast(pair[1]), .vtable = @ptrCast(vt) };
        }
        return self;
    }

    pub fn bind(self: *const Scope, comptime E: type, handler_ptr: anytype) Scope {
        const H = HandlerType(@TypeOf(handler_ptr));
        const s = E.ensureSlot();
        const vt = comptime E.makeVtable(H);
        var copy = self.*;
        copy._slots[s] = .{ .state = @ptrCast(handler_ptr), .vtable = @ptrCast(vt) };
        return copy;
    }
};

// ── Contract — comptime-checked effect bundle ────────────────────────

pub fn Contract(comptime effects: anytype) type {
    return struct {
        pub fn init(pairs: anytype) Scope {
            inline for (effects) |E| {
                if (comptime !pairsProvide(@TypeOf(pairs), E))
                    @compileError("Contract: missing handler for " ++ @typeName(E));
            }
            return Scope.init(pairs);
        }

        fn pairsProvide(comptime Pairs: type, comptime E: type) bool {
            for (@typeInfo(Pairs).@"struct".fields) |f| {
                const inner = @typeInfo(f.type).@"struct".fields;
                if (inner[0].is_comptime) {
                    const ptr: *const type = @ptrCast(@alignCast(inner[0].default_value_ptr.?));
                    if (ptr.* == E) return true;
                }
            }
            return false;
        }
    };
}

// ── Exit — handler-directed early exit with a payload ────────────────

/// One-shot "abort" semantics on top of Zig error unions: a handler that
/// wants to stop the computation and deliver a result to the scope's
/// installer embeds an `Exit(T)`, calls `abort(value)`, and returns the
/// resulting `error.FxAbort`. Business logic propagates it with `try`;
/// the installation site catches `error.FxAbort` and reads `payload`.
///
/// Operations that may abort declare it in their result type:
///   check: fx.Op(u64, error{FxAbort}!void)
///
/// Caveats: `error.FxAbort` is one shared error value, so `payload` is only
/// meaningful for the Exit embedded in the handler *you* installed — with
/// multiple abort-capable handlers in a scope, check each one's payload.
/// Reset `payload` to null before reusing a handler across runs.
pub fn Exit(comptime T: type) type {
    if (@typeInfo(T) == .optional)
        @compileError("Exit(T) does not support optional T: abort(null) would be indistinguishable from 'never aborted'");
    return struct {
        payload: ?T = null,

        pub fn abort(self: *@This(), value: T) error{FxAbort} {
            self.payload = value;
            return error.FxAbort;
        }
    };
}

// ── Helpers ───────────────────────────────────────────────────────────

fn HandlerType(comptime PtrType: type) type {
    const info = @typeInfo(PtrType);
    if (info != .pointer) @compileError("Expected pointer to handler struct");
    if (info.pointer.is_const) @compileError("Handler must be a mutable pointer (*T), not *const T — declare handler with 'var'");
    return info.pointer.child;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

const TestLogger = Effect(union(enum) {
    info: Op([]const u8, void),
    err: Op([]const u8, void),
});

const TestConfig = Effect(union(enum) {
    get: Op([]const u8, ?[]const u8),
});

const StderrLoggerHandler = struct {
    call_count: usize = 0,

    fn info(self: *StderrLoggerHandler, _: []const u8) void {
        self.call_count += 1;
    }

    fn err(self: *StderrLoggerHandler, _: []const u8) void {
        self.call_count += 1;
    }
};

const AltLoggerHandler = struct {
    call_count: usize = 0,

    fn info(self: *AltLoggerHandler, _: []const u8) void {
        self.call_count += 1;
    }

    fn err(self: *AltLoggerHandler, _: []const u8) void {
        self.call_count += 1;
    }
};

const MapConfigHandler = struct {
    value: ?[]const u8 = null,

    fn get(self: *MapConfigHandler, _: []const u8) ?[]const u8 {
        return self.value;
    }
};

// ── Test: basic void effect ───────────────────────────────────────────

test "basic void effect" {
    var handler = StderrLoggerHandler{};
    const sc = Scope.init(.{.{ TestLogger, &handler }});

    TestLogger.exec(&sc, .info, "hello");
    TestLogger.exec(&sc, .err, "oh no");

    try testing.expectEqual(@as(usize, 2), handler.call_count);
}

// ── Test: effect with return values ───────────────────────────────────

test "effect with return values" {
    var config = MapConfigHandler{ .value = "42" };
    const sc = Scope.init(.{.{ TestConfig, &config }});

    const result = TestConfig.exec(&sc, .get, "key");
    try testing.expectEqualStrings("42", result.?);
}

// ── Test: multiple effects ────────────────────────────────────────────

test "multiple effects" {
    var logger = StderrLoggerHandler{};
    var config = MapConfigHandler{ .value = "hello" };

    const sc = Scope.init(.{
        .{ TestLogger, &logger },
        .{ TestConfig, &config },
    });

    TestLogger.exec(&sc, .info, "msg");
    const val = TestConfig.exec(&sc, .get, "key");

    try testing.expectEqual(@as(usize, 1), logger.call_count);
    try testing.expectEqualStrings("hello", val.?);
}

// ── Test: missing handler detected ────────────────────────────────────

const UninstalledEffect = Effect(union(enum) {
    do_thing: Op(u32, void),
});

test "missing handler detected" {
    try testing.expectEqual(UNASSIGNED, UninstalledEffect.slot);
}

// ── Test: error union return type ─────────────────────────────────────

const TestFallible = Effect(union(enum) {
    check: Op([]const u8, anyerror!bool),
});

const FallibleHandler = struct {
    should_fail: bool = false,

    fn check(self: *FallibleHandler, _: []const u8) anyerror!bool {
        if (self.should_fail) return error.TestFailure;
        return true;
    }
};

test "error union return type" {
    var handler = FallibleHandler{};
    const sc = Scope.init(.{.{ TestFallible, &handler }});

    const result = try TestFallible.exec(&sc, .check, "test");
    try testing.expect(result);

    handler.should_fail = true;
    const err_result = TestFallible.exec(&sc, .check, "test");
    try testing.expectError(error.TestFailure, err_result);
}

// ── Test: void-arg operation ─────────────────────────────────────────

const TestClock = Effect(union(enum) {
    now: Op(void, i64),
});

const FixedClockHandler = struct {
    time: i64 = 1000,

    fn now(self: *FixedClockHandler) i64 {
        return self.time;
    }
};

test "void-arg operation" {
    var clock = FixedClockHandler{ .time = 42 };
    const sc = Scope.init(.{.{ TestClock, &clock }});

    const result = TestClock.exec(&sc, .now, {});
    try testing.expectEqual(@as(i64, 42), result);
}

// ── Test: bind creates independent scope ─────────────────────────────

test "bind creates independent scope" {
    var a = StderrLoggerHandler{};
    var b = AltLoggerHandler{};

    const parent = Scope.init(.{.{ TestLogger, &a }});
    const child = parent.bind(TestLogger, &b);

    TestLogger.exec(&parent, .info, "to parent");
    TestLogger.exec(&child, .info, "to child");

    try testing.expectEqual(@as(usize, 1), a.call_count);
    try testing.expectEqual(@as(usize, 1), b.call_count);
}

// ── Test: bind preserves other handlers ──────────────────────────────

test "bind preserves other handlers" {
    var logger = StderrLoggerHandler{};
    var config = MapConfigHandler{ .value = "inherited" };

    const parent = Scope.init(.{
        .{ TestLogger, &logger },
        .{ TestConfig, &config },
    });

    var alt_logger = AltLoggerHandler{};
    const child = parent.bind(TestLogger, &alt_logger);

    TestLogger.exec(&child, .info, "msg");
    const val = TestConfig.exec(&child, .get, "key");

    try testing.expectEqual(@as(usize, 1), alt_logger.call_count);
    try testing.expectEqualStrings("inherited", val.?);
}

// ── Test: nested bind scopes ─────────────────────────────────────────

test "nested bind scopes" {
    var a = StderrLoggerHandler{};
    var b = AltLoggerHandler{};
    var c = StderrLoggerHandler{};

    const root_env = Scope.init(.{.{ TestLogger, &a }});
    const mid = root_env.bind(TestLogger, &b);
    const leaf = mid.bind(TestLogger, &c);

    TestLogger.exec(&root_env, .info, "a");
    TestLogger.exec(&mid, .info, "b");
    TestLogger.exec(&leaf, .info, "c");

    try testing.expectEqual(@as(usize, 1), a.call_count);
    try testing.expectEqual(@as(usize, 1), b.call_count);
    try testing.expectEqual(@as(usize, 1), c.call_count);
}

// ── Test: different operations dispatch independently ────────────────

const MultiOpHandler = struct {
    info_count: usize = 0,
    err_count: usize = 0,

    fn info(self: *MultiOpHandler, _: []const u8) void {
        self.info_count += 1;
    }

    fn err(self: *MultiOpHandler, _: []const u8) void {
        self.err_count += 1;
    }
};

test "different operations dispatch independently" {
    var handler = MultiOpHandler{};
    const sc = Scope.init(.{.{ TestLogger, &handler }});

    TestLogger.exec(&sc, .info, "a");
    TestLogger.exec(&sc, .info, "b");
    TestLogger.exec(&sc, .err, "c");

    try testing.expectEqual(@as(usize, 2), handler.info_count);
    try testing.expectEqual(@as(usize, 1), handler.err_count);
}

// ── Test: passed as parameter ────────────────────────────────────────

test "passed as parameter" {
    var logger = StderrLoggerHandler{};
    const sc = Scope.init(.{.{ TestLogger, &logger }});

    const S = struct {
        fn doWork(fx: *const Scope) void {
            TestLogger.exec(fx, .info, "from helper");
        }
    };

    S.doWork(&sc);
    try testing.expectEqual(@as(usize, 1), logger.call_count);
}

// ── Test: cross-thread via pointer ───────────────────────────────────

test "cross-thread via pointer" {
    var handler = StderrLoggerHandler{};
    const sc = Scope.init(.{.{ TestLogger, &handler }});

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(fx: *const Scope) void {
            TestLogger.exec(fx, .info, "from child thread");
        }
    }.run, .{&sc});
    thread.join();

    try testing.expectEqual(@as(usize, 1), handler.call_count);
}

// ── Test: bind returns new scope ─────────────────────────────────────

test "bind returns new scope" {
    var a = MapConfigHandler{ .value = "first" };
    const sc = Scope.init(.{.{ TestConfig, &a }});
    try testing.expectEqualStrings("first", TestConfig.exec(&sc, .get, "k").?);

    var b = MapConfigHandler{ .value = "second" };
    const sc2 = sc.bind(TestConfig, &b);
    try testing.expectEqualStrings("second", TestConfig.exec(&sc2, .get, "k").?);
    try testing.expectEqualStrings("first", TestConfig.exec(&sc, .get, "k").?);
}

const SetOnlyEffect = Effect(union(enum) {
    ping: Op(void, u32),
});

const SetOnlyHandler = struct {
    fn ping(_: *SetOnlyHandler) u32 {
        return 99;
    }
};

test "single effect" {
    var handler = SetOnlyHandler{};
    const sc = Scope.init(.{.{ SetOnlyEffect, &handler }});

    const result = SetOnlyEffect.exec(&sc, .ping, {});
    try testing.expectEqual(@as(u32, 99), result);
}

// ── Test: handler receives scope for cross-effect dispatch ───────────

const CrossEffectLogger = Effect(union(enum) {
    log_and_count: Op([]const u8, void),
});

const CrossEffectCounter = Effect(union(enum) {
    inc: Op(void, void),
});

const CounterHandler = struct {
    count: usize = 0,
    fn inc(self: *CounterHandler) void {
        self.count += 1;
    }
};

const CrossCallingHandler = struct {
    fn log_and_count(self: *CrossCallingHandler, sc: *const Scope, _: []const u8) void {
        _ = self;
        CrossEffectCounter.exec(sc, .inc, {});
    }
};

test "handler receives scope for cross-effect dispatch" {
    var counter = CounterHandler{};
    var logger = CrossCallingHandler{};
    const sc = Scope.init(.{
        .{ CrossEffectLogger, &logger },
        .{ CrossEffectCounter, &counter },
    });

    CrossEffectLogger.exec(&sc, .log_and_count, "hello");
    CrossEffectLogger.exec(&sc, .log_and_count, "world");

    try testing.expectEqual(@as(usize, 2), counter.count);
}

// ── Test: contract init succeeds for complete pairs ─────────────────

test "contract init succeeds for complete pairs" {
    const Proto = Contract(.{ TestLogger, TestConfig });

    var logger = StderrLoggerHandler{};
    var config = MapConfigHandler{ .value = "ok" };

    const sc = Proto.init(.{
        .{ TestLogger, &logger },
        .{ TestConfig, &config },
    });

    TestLogger.exec(&sc, .info, "hello");
    try testing.expectEqual(@as(usize, 1), logger.call_count);
}

// ── Test: contract allows extra effects ─────────────────────────────

test "contract allows extra effects" {
    const Proto = Contract(.{TestLogger});

    var logger = StderrLoggerHandler{};
    var config = MapConfigHandler{ .value = "extra" };

    const sc = Proto.init(.{
        .{ TestLogger, &logger },
        .{ TestConfig, &config },
    });

    const val = TestConfig.exec(&sc, .get, "key");
    try testing.expectEqualStrings("extra", val.?);
}

// ── Test: optional behavior via no-op handlers ─────────────────────

const OptionalMetrics = Effect(union(enum) {
    inc: Op([]const u8, void),
});

const NoopMetricsHandler = struct {
    fn inc(_: *NoopMetricsHandler, _: []const u8) void {}
};

const CountingMetricsHandler = struct {
    count: usize = 0,

    fn inc(self: *CountingMetricsHandler, _: []const u8) void {
        self.count += 1;
    }
};

// ── Test: Exit delivers a payload to the installer ──────────────────

const Budget = Effect(union(enum) {
    spend: Op(u64, error{FxAbort}!void),
});

const BudgetHandler = struct {
    remaining: u64,
    exit: Exit(u64) = .{},

    fn spend(self: *BudgetHandler, amount: u64) error{FxAbort}!void {
        if (amount > self.remaining) return self.exit.abort(self.remaining);
        self.remaining -= amount;
    }
};

fn spendAll(sc: *const Scope, costs: []const u64) error{FxAbort}!usize {
    for (costs) |cost| try Budget.exec(sc, .spend, cost);
    return costs.len;
}

test "Exit delivers a payload to the installer" {
    var budget = BudgetHandler{ .remaining = 10 };
    const sc = Scope.init(.{.{ Budget, &budget }});

    const result = spendAll(&sc, &.{ 4, 3, 9, 1 });
    try testing.expectError(error.FxAbort, result);
    try testing.expectEqual(@as(?u64, 3), budget.exit.payload);

    // A run that fits the budget completes normally.
    var budget2 = BudgetHandler{ .remaining = 10 };
    const sc2 = Scope.init(.{.{ Budget, &budget2 }});
    try testing.expectEqual(@as(usize, 3), try spendAll(&sc2, &.{ 4, 3, 3 }));
    try testing.expectEqual(@as(?u64, null), budget2.exit.payload);
}

test "contract models optional effects with no-op handlers" {
    const App = Contract(.{ TestLogger, OptionalMetrics });

    var logger = StderrLoggerHandler{};
    var noop_metrics = NoopMetricsHandler{};

    const sc = App.init(.{
        .{ TestLogger, &logger },
        .{ OptionalMetrics, &noop_metrics },
    });

    TestLogger.exec(&sc, .info, "work started");
    OptionalMetrics.exec(&sc, .inc, "work.count");

    try testing.expectEqual(@as(usize, 1), logger.call_count);

    var real_metrics = CountingMetricsHandler{};
    const observed = sc.bind(OptionalMetrics, &real_metrics);
    OptionalMetrics.exec(&observed, .inc, "work.count");

    try testing.expectEqual(@as(usize, 1), real_metrics.count);
}
