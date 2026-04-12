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
        var vtable_fields: [fields.len]std.builtin.Type.StructField = undefined;
        for (fields, 0..) |field, i| {
            const OpType = field.type;
            if (!isOpType(OpType))
                @compileError("Effect union variant '" ++ field.name ++ "' must have an Op(...) payload");
            const FnPtr = *const fn (*anyopaque, OpType.ArgType) OpType.ResultType;
            vtable_fields[i] = .{
                .name = field.name,
                .type = FnPtr,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(FnPtr),
            };
        }
        break :blk @Type(.{ .@"struct" = .{
            .layout = .auto,
            .fields = &vtable_fields,
            .decls = &.{},
            .is_tuple = false,
        } });
    };

    return struct {
        const Self = @This();

        pub var slot: usize = UNASSIGNED;

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

                    if (MethodInfo.params.len != 2) {
                        @compileError("Handler method '" ++ field.name ++ "' on '" ++ @typeName(H) ++ "' must take (*Self, ArgType)");
                    }
                    if (MethodInfo.params[0].type != *H) {
                        @compileError("Handler method '" ++ field.name ++ "' on '" ++ @typeName(H) ++ "' first parameter must be *" ++ @typeName(H));
                    }
                    if (MethodInfo.return_type != OpType.ResultType) {
                        @compileError("Handler method '" ++ field.name ++ "' on '" ++ @typeName(H) ++ "' has wrong return type");
                    }

                    const trampoline = struct {
                        fn call(opaque_ptr: *anyopaque, arg: OpType.ArgType) OpType.ResultType {
                            const self: *H = @ptrCast(@alignCast(opaque_ptr));
                            return @field(H, field.name)(self, arg);
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
            const s = @atomicLoad(usize, &slot, .monotonic);
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
        const E = pair[0];
        const handler_ptr = pair[1];
        const H = HandlerType(@TypeOf(handler_ptr));
        const s = E.ensureSlot();
        const vt = comptime E.makeVtable(H);
        slots[s] = .{ .state = @ptrCast(handler_ptr), .vtable = @ptrCast(vt) };
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
