const std = @import("std");
const testing = std.testing;
const root = @import("root");

// ── Configuration ─────────────────────────────────────────────────────

pub const MAX_EFFECTS: usize = if (@hasDecl(root, "libfx_max_effects"))
    root.libfx_max_effects
else
    64;

// ── Constants ─────────────────────────────────────────────────────────

const UNASSIGNED = std.math.maxInt(usize);

var next_slot: usize = 0;

// ── Threadlocal effect slots ──────────────────────────────────────────

const Slot = struct {
    state: *anyopaque = undefined,
    vtable: *const anyopaque = undefined,
};

threadlocal var slots: [MAX_EFFECTS]Slot = @splat(Slot{});

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

// ── ResetToken ────────────────────────────────────────────────────────

pub const ResetToken = struct {
    index: usize,
    prev: Slot,
};

// ── Effect — dispatchable effect type from a tagged union ─────────────

pub fn Effect(comptime U: type) type {
    const union_info = @typeInfo(U).@"union";
    const fields = union_info.fields;

    // Vtable: a struct with one typed trampoline function pointer per operation.
    const Vtable = comptime blk: {
        var field_names: [fields.len][:0]const u8 = undefined;
        var field_types: [fields.len]type = undefined;
        for (fields, 0..) |field, i| {
            const OpType = field.type;
            if (!isOpType(OpType))
                @compileError("Effect union variant '" ++ field.name ++ "' must have an Op(...) payload");
            field_names[i] = field.name;
            field_types[i] = *const fn (*anyopaque, OpType.ArgType) OpType.ResultType;
        }
        break :blk @Struct(.auto, null, &field_names, &field_types, &@splat(.{}));
    };

    return struct {
        const Self = @This();

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

        fn makeVtable(comptime H: type) *const Vtable {
            const vtable = comptime blk: {
                var vt: Vtable = undefined;
                for (fields) |field| {
                    const OpType = field.type;
                    if (!@hasDecl(H, field.name)) {
                        @compileError("Handler '" ++ @typeName(H) ++ "' is missing method '" ++ field.name ++ "'");
                    }
                    const method = @field(H, field.name);
                    const MethodInfo = @typeInfo(@TypeOf(method)).@"fn";

                    const expect_params: usize = if (OpType.ArgType == void) 1 else 2;
                    if (MethodInfo.params.len != expect_params) {
                        @compileError("Handler method '" ++ field.name ++ "' on '" ++ @typeName(H) ++ "' has wrong number of parameters");
                    }
                    if (MethodInfo.return_type != OpType.ResultType) {
                        @compileError("Handler method '" ++ field.name ++ "' on '" ++ @typeName(H) ++ "' has wrong return type");
                    }

                    const trampoline = struct {
                        fn call(opaque_ptr: *anyopaque, arg: OpType.ArgType) OpType.ResultType {
                            const self: *H = @ptrCast(@alignCast(opaque_ptr));
                            if (OpType.ArgType == void) {
                                return @field(H, field.name)(self);
                            } else {
                                return @field(H, field.name)(self, arg);
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
            comptime op: std.meta.FieldEnum(U),
            arg: fields[@intFromEnum(op)].type.ArgType,
        ) fields[@intFromEnum(op)].type.ResultType {
            const s = @atomicLoad(usize, &slot, .acquire);
            const entry = slots[s];
            const vt: *const Vtable = @ptrCast(@alignCast(entry.vtable));
            const trampoline = @field(vt.*, fields[@intFromEnum(op)].name);
            return trampoline(entry.state, arg);
        }
    };
}

// ── init — batch-install handlers ─────────────────────────────────────

/// Install one or more effect handlers. Each tuple element is
/// `.{ EffectType, &handler_struct }`. Assigns slot IDs on first use.
///
///   fx.init(.{
///       .{ Logger, &logger },
///       .{ Config, &config },
///   });
pub fn init(pairs: anytype) void {
    inline for (pairs) |pair| {
        _ = set(pair[0], pair[1]);
    }
}

// ── set — swap a single handler ───────────────────────────────────────

/// Swap one handler, returning a `ResetToken` for the previous state.
/// Works with or without a prior `init`. If no handler was previously
/// installed, calling `exec` after `reset` is undefined behavior.
pub fn set(comptime E: type, handler_ptr: anytype) ResetToken {
    const H = HandlerType(@TypeOf(handler_ptr));
    const s = E.ensureSlot();
    const token = ResetToken{ .index = s, .prev = slots[s] };
    const vt = comptime E.makeVtable(H);
    slots[s] = .{ .state = @ptrCast(handler_ptr), .vtable = @ptrCast(vt) };
    return token;
}

// ── reset — restore previous handler ──────────────────────────────────

/// Restore a previous handler from a `ResetToken`. Pair with `defer`
/// for scoped handler swaps.
pub fn reset(token: ResetToken) void {
    slots[token.index] = token.prev;
}

// ── snapshot/restore — propagate effects across threads ───────────────

/// A copy of the threadlocal slots array. 1KB at the default MAX_EFFECTS.
/// Handler state pointers inside must outlive any thread using the snapshot.
pub const Snapshot = [MAX_EFFECTS]Slot;

/// Capture the current thread's installed handlers.
pub fn snapshot() Snapshot {
    return slots;
}

/// Install a snapshot into the current thread's slots.
pub fn restore(snap: Snapshot) void {
    slots = snap;
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
    init(.{.{ TestLogger, &handler }});

    TestLogger.exec(.info, "hello");
    TestLogger.exec(.err, "oh no");

    try testing.expectEqual(@as(usize, 2), handler.call_count);
}

// ── Test: effect with return values ───────────────────────────────────

test "effect with return values" {
    var config = MapConfigHandler{ .value = "42" };
    init(.{.{ TestConfig, &config }});

    const result = TestConfig.exec(.get, "key");
    try testing.expectEqualStrings("42", result.?);
}

// ── Test: set/reset scoping ───────────────────────────────────────────

test "set/reset scoping" {
    var handler_a = StderrLoggerHandler{};
    init(.{.{ TestLogger, &handler_a }});

    TestLogger.exec(.info, "from A");
    try testing.expectEqual(@as(usize, 1), handler_a.call_count);

    var handler_b = AltLoggerHandler{};
    const token = set(TestLogger, &handler_b);

    TestLogger.exec(.info, "from B");
    try testing.expectEqual(@as(usize, 1), handler_b.call_count);
    try testing.expectEqual(@as(usize, 1), handler_a.call_count);

    reset(token);

    TestLogger.exec(.info, "from A again");
    try testing.expectEqual(@as(usize, 2), handler_a.call_count);
}

// ── Test: multiple effects ────────────────────────────────────────────

test "multiple effects" {
    var logger = StderrLoggerHandler{};
    var config = MapConfigHandler{ .value = "hello" };

    init(.{
        .{ TestLogger, &logger },
        .{ TestConfig, &config },
    });

    TestLogger.exec(.info, "msg");
    const val = TestConfig.exec(.get, "key");

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
    init(.{.{ TestFallible, &handler }});

    const result = try TestFallible.exec(.check, "test");
    try testing.expect(result);

    handler.should_fail = true;
    const err_result = TestFallible.exec(.check, "test");
    try testing.expectError(error.TestFailure, err_result);
}

// ── Test: snapshot/restore across threads ─────────────────────────────

test "snapshot/restore across thread" {
    var handler = StderrLoggerHandler{};
    init(.{.{ TestLogger, &handler }});

    const snap = snapshot();
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: Snapshot) void {
            restore(s);
            TestLogger.exec(.info, "from child thread");
        }
    }.run, .{snap});
    thread.join();

    try testing.expectEqual(@as(usize, 1), handler.call_count);
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
    init(.{.{ TestClock, &clock }});

    const result = TestClock.exec(.now, {});
    try testing.expectEqual(@as(i64, 42), result);
}

// ── Test: nested set/reset ───────────────────────────────────────────

test "nested set/reset restores correctly" {
    var a = StderrLoggerHandler{};
    var b = AltLoggerHandler{};
    var c = StderrLoggerHandler{};
    init(.{.{ TestLogger, &a }});

    TestLogger.exec(.info, "a");
    try testing.expectEqual(@as(usize, 1), a.call_count);

    const token1 = set(TestLogger, &b);
    TestLogger.exec(.info, "b");
    try testing.expectEqual(@as(usize, 1), b.call_count);

    const token2 = set(TestLogger, &c);
    TestLogger.exec(.info, "c");
    try testing.expectEqual(@as(usize, 1), c.call_count);

    reset(token2);
    TestLogger.exec(.info, "b again");
    try testing.expectEqual(@as(usize, 2), b.call_count);

    reset(token1);
    TestLogger.exec(.info, "a again");
    try testing.expectEqual(@as(usize, 2), a.call_count);
}

// ── Test: set without prior init ─────────────────────────────────────

const SetOnlyEffect = Effect(union(enum) {
    ping: Op(void, u32),
});

const SetOnlyHandler = struct {
    fn ping(_: *SetOnlyHandler) u32 {
        return 99;
    }
};

test "set without prior init" {
    var handler = SetOnlyHandler{};
    const token = set(SetOnlyEffect, &handler);
    defer reset(token);

    const result = SetOnlyEffect.exec(.ping, {});
    try testing.expectEqual(@as(u32, 99), result);
}

// ── Test: init overwrites previous handler ───────────────────────────

test "init overwrites previous handler" {
    var a = MapConfigHandler{ .value = "first" };
    init(.{.{ TestConfig, &a }});
    try testing.expectEqualStrings("first", TestConfig.exec(.get, "k").?);

    var b = MapConfigHandler{ .value = "second" };
    init(.{.{ TestConfig, &b }});
    try testing.expectEqualStrings("second", TestConfig.exec(.get, "k").?);
}

// ── Test: different operations hit correct vtable entries ─────────────

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
    init(.{.{ TestLogger, &handler }});

    TestLogger.exec(.info, "a");
    TestLogger.exec(.info, "b");
    TestLogger.exec(.err, "c");

    try testing.expectEqual(@as(usize, 2), handler.info_count);
    try testing.expectEqual(@as(usize, 1), handler.err_count);
}

// ── Test: snapshot captures swapped handler ───────────────────────────

test "snapshot captures swapped handler" {
    var a = StderrLoggerHandler{};
    var b = AltLoggerHandler{};
    init(.{.{ TestLogger, &a }});

    const token = set(TestLogger, &b);
    defer reset(token);

    // Snapshot after swap — should capture b, not a
    const snap = snapshot();
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: Snapshot) void {
            restore(s);
            TestLogger.exec(.info, "from child");
        }
    }.run, .{snap});
    thread.join();

    try testing.expectEqual(@as(usize, 1), b.call_count);
    try testing.expectEqual(@as(usize, 0), a.call_count);
}
