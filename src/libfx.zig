const std = @import("std");
const testing = std.testing;

// ── Constants ──────────────────────────────────────────────────────────

const UNASSIGNED = std.math.maxInt(usize);
const MAX_EFFECTS = 32;

// ── Global slot counter (atomic, monotonically increasing) ─────────────

var next_slot: usize = 0;

// ── Threadlocal effect arrays ──────────────────────────────────────────

threadlocal var states: [MAX_EFFECTS]*anyopaque = undefined;
threadlocal var vtables: [MAX_EFFECTS]*const anyopaque = undefined;
threadlocal var installed: [MAX_EFFECTS]bool = .{false} ** MAX_EFFECTS;

// ── Op — operation signature marker ────────────────────────────────────

/// Marker for an effect operation's argument and return types.
/// Use as a union variant payload inside the union passed to `Effect()`.
///
///   fx.Op([]const u8, void)         — void-returning operation
///   fx.Op([]const u8, ?[]const u8)  — operation with a return type
pub fn Op(comptime Arg: type, comptime Result: type) type {
    return struct {
        pub const ArgType = Arg;
        pub const ResultType = Result;
        _phantom: u0 = 0,
    };
}

fn isOpType(comptime T: type) bool {
    return @hasDecl(T, "ArgType") and @hasDecl(T, "ResultType");
}

// ── ResetToken ─────────────────────────────────────────────────────────

pub const ResetToken = struct {
    slot_index: usize,
    prev_state: *anyopaque,
    prev_vtable: *const anyopaque,
    prev_installed: bool,
};

// ── Effect — generate a dispatchable effect type from a tagged union ───

pub fn Effect(comptime U: type) type {
    const union_info = @typeInfo(U).@"union";
    const fields = union_info.fields;

    // Vtable: a struct with one field per operation, each a typed
    // trampoline function pointer.
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

        /// Runtime-assigned slot index. Write-once via `ensureSlot()`.
        pub var slot: usize = UNASSIGNED;

        /// Atomically assign a slot index on first use.
        pub fn ensureSlot() usize {
            const current = @atomicLoad(usize, &slot, .acquire);
            if (current != UNASSIGNED) return current;

            const new_slot = @atomicRmw(usize, &next_slot, .Add, 1, .acq_rel);
            if (new_slot >= MAX_EFFECTS) @panic("too many effects");

            return @cmpxchgStrong(usize, &slot, UNASSIGNED, new_slot, .acq_rel, .acquire) orelse new_slot;
        }

        /// Generate a static vtable for handler type H at comptime.
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

        /// Install a handler for this effect.
        pub fn install(comptime H: type, handler: *H) void {
            const s = ensureSlot();
            const vt = comptime makeVtable(H);
            states[s] = @ptrCast(handler);
            vtables[s] = @ptrCast(vt);
            installed[s] = true;
        }

        /// Swap handler, returning a token to restore the previous one.
        pub fn swap(comptime H: type, handler: *H) ResetToken {
            const s = ensureSlot();
            const token = ResetToken{
                .slot_index = s,
                .prev_state = states[s],
                .prev_vtable = vtables[s],
                .prev_installed = installed[s],
            };
            const vt = comptime makeVtable(H);
            states[s] = @ptrCast(handler);
            vtables[s] = @ptrCast(vt);
            installed[s] = true;
            return token;
        }

        /// Dispatch an operation by comptime enum tag.
        ///
        ///   Logger.exec(.info, "hello")
        ///   Config.exec(.get, "key")
        pub fn exec(
            comptime op: std.meta.FieldEnum(U),
            arg: fields[@intFromEnum(op)].type.ArgType,
        ) fields[@intFromEnum(op)].type.ResultType {
            const s = @atomicLoad(usize, &slot, .acquire);
            if (s == UNASSIGNED or !installed[s])
                @panic("effect not installed: " ++ @typeName(Self));
            const vt: *const Vtable = @ptrCast(@alignCast(vtables[s]));
            const trampoline = @field(vt.*, fields[@intFromEnum(op)].name);
            return trampoline(states[s], arg);
        }
    };
}

// ── init — batch-install handlers ──────────────────────────────────────

/// Install one or more effect handlers. Each element of the tuple is
/// a `.{ EffectType, &handler_struct }` pair.
///
///   fx.init(.{
///       .{ Logger, &logger },
///       .{ Config, &config },
///   });
pub fn init(pairs: anytype) void {
    inline for (pairs) |pair| {
        const EffectType = pair[0];
        const handler = pair[1];
        const H = EffectHandlerType(@TypeOf(handler));
        EffectType.install(H, @constCast(handler));
    }
}

fn EffectHandlerType(comptime PtrType: type) type {
    const info = @typeInfo(PtrType);
    if (info != .pointer) @compileError("Expected pointer to handler struct");
    return info.pointer.child;
}

// ── set — swap a single handler ────────────────────────────────────────

/// Swap a single effect's handler. Returns a `ResetToken` capturing
/// the previous state for later restoration via `reset()`.
pub fn set(comptime EffectType: type, handler: anytype) ResetToken {
    const H = EffectHandlerType(@TypeOf(handler));
    return EffectType.swap(H, @constCast(handler));
}

// ── reset — restore previous handler ───────────────────────────────────

/// Restore a previous handler from a `ResetToken`. Pair with `defer`
/// for scoped handler swaps.
pub fn reset(token: ResetToken) void {
    states[token.slot_index] = token.prev_state;
    vtables[token.slot_index] = token.prev_vtable;
    installed[token.slot_index] = token.prev_installed;
}

// ════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════

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
    tag: []const u8 = "alt",
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

// ── Test: basic void effect ────────────────────────────────────────────

test "basic void effect" {
    var handler = StderrLoggerHandler{};
    init(.{.{ TestLogger, &handler }});

    TestLogger.exec(.info, "hello");
    TestLogger.exec(.err, "oh no");

    try testing.expectEqual(@as(usize, 2), handler.call_count);
}

// ── Test: effect with return values ────────────────────────────────────

test "effect with return values" {
    var config = MapConfigHandler{ .value = "42" };
    init(.{.{ TestConfig, &config }});

    const result = TestConfig.exec(.get, "key");
    try testing.expectEqualStrings("42", result.?);
}

// ── Test: set/reset scoping ────────────────────────────────────────────

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

// ── Test: multiple effects ─────────────────────────────────────────────

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

// ── Test: missing handler panics ───────────────────────────────────────

const UninstalledEffect = Effect(union(enum) {
    do_thing: Op(u32, void),
});

test "missing handler detected" {
    // Verify the slot is unassigned for an effect that was never installed.
    // Calling UninstalledEffect.exec(.do_thing, 42) would panic at runtime.
    try testing.expectEqual(UNASSIGNED, UninstalledEffect.slot);
}
