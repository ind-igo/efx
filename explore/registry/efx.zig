const std = @import("std");
const testing = std.testing;
const root = @import("root");

// ── Configuration ─────────────────────────────────────────────────────

/// Whole-program list of effects. Layout comes from here, at compile time.
pub const MAX_EFFECTS: usize = root.efx_effects.len;
const columns = @hasDecl(root, "efx_columns") and root.efx_columns;

fn registrySlot(comptime E: type) usize {
    for (root.efx_effects, 0..) |T, i| if (T == E) return i + 1;
    @compileError("effect is missing from root.efx_effects: " ++ @typeName(E));
}
fn opCount(comptime E: type) usize {
    return @typeInfo(E.Union).@"union".field_names.len;
}
const total_ops: usize = blk: {
    var n: usize = 0;
    for (root.efx_effects) |T| n += opCount(T);
    break :blk n;
};
fn opBase(comptime E: type) usize {
    var n: usize = 0;
    for (root.efx_effects) |T| {
        if (T == E) return n;
        n += opCount(T);
    }
    unreachable;
}

// ── Constants ─────────────────────────────────────────────────────────

/// Slot 0 is never bound in any scope. An effect's slot starts here, so an
/// effect that was never assigned one reads an empty slot, and `exec` needs
/// only the one test for "no handler".
const UNASSIGNED: usize = 0;

pub const Slot = struct {
    state: *anyopaque = undefined,
    vtable: *const anyopaque = undefined,
};

// ── Op — operation signature marker ───────────────────────────────────

/// Operation signature: `Op(ArgType, ReturnType)`.
/// Use as a union variant payload inside the union passed to `Effect()`.
///
///   efx.Op([]const u8, void)         — void-returning operation
///   efx.Op([]const u8, ?[]const u8)  — operation with a return type
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
    const op_names = union_info.field_names;
    const op_types = union_info.field_types;

    const Vtable = comptime blk: {
        var fn_types: [op_names.len]type = undefined;
        for (op_names, op_types, 0..) |name, OpType, i| {
            if (!isOpType(OpType))
                @compileError("Effect union variant '" ++ name ++ "' must have an Op(...) payload");
            fn_types[i] = *const fn (*anyopaque, *const Scope, OpType.ArgType) OpType.ResultType;
        }
        break :blk @Struct(.auto, null, op_names, &fn_types, &@splat(.{}));
    };

    return struct {
        const Self = @This();

        pub const Union = U;
        pub const slot: usize = registrySlot(Self);

        pub fn ensureSlot() usize {
            return slot;
        }

        /// Stands in for a missing handler. `exec` selects it instead of
        /// branching, which keeps the panic out of the dispatch path.
        pub const unbound: Vtable = blk: {
            var vt: Vtable = undefined;
            for (op_names, op_types) |name, OpType| {
                const stub = struct {
                    fn call(_: *anyopaque, _: *const Scope, _: OpType.ArgType) OpType.ResultType {
                        @panic("efx: no handler bound in this scope for " ++ @typeName(U));
                    }
                };
                @field(vt, name) = &stub.call;
            }
            break :blk vt;
        };

        pub fn makeVtable(comptime H: type) *const Vtable {
            const vtable = comptime blk: {
                var vt: Vtable = undefined;
                for (op_names, op_types) |name, OpType| {
                    if (!@hasDecl(H, name)) {
                        @compileError("Handler '" ++ @typeName(H) ++ "' is missing method '" ++ name ++ "'");
                    }
                    const method = @field(H, name);
                    const MethodInfo = @typeInfo(@TypeOf(method)).@"fn";
                    const has_arg = OpType.ArgType != void;
                    const base_params: usize = if (has_arg) 2 else 1;

                    const wants_scope = if (MethodInfo.param_types.len == base_params + 1) true else if (MethodInfo.param_types.len == base_params) false else @compileError("Handler method '" ++ name ++ "' on '" ++ @typeName(H) ++ "' has wrong number of parameters");

                    if (MethodInfo.return_type != OpType.ResultType) {
                        @compileError("Handler method '" ++ name ++ "' on '" ++ @typeName(H) ++ "' has wrong return type");
                    }

                    const trampoline = struct {
                        fn call(opaque_ptr: *anyopaque, sc: *const Scope, arg: OpType.ArgType) OpType.ResultType {
                            const self: *H = @ptrCast(@alignCast(opaque_ptr));
                            if (wants_scope) {
                                if (has_arg) return @field(H, name)(self, sc, arg) else return @field(H, name)(self, sc);
                            } else {
                                if (has_arg) return @field(H, name)(self, arg) else return @field(H, name)(self);
                            }
                        }
                    };
                    @field(vt, name) = &trampoline.call;
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
            arg: op_types[@backingInt(op)].ArgType,
        ) op_types[@backingInt(op)].ResultType {
            const name = op_names[@backingInt(op)];
            if (columns) {
                const Fn = @TypeOf(@field(unbound, name));
                const f: Fn = @ptrCast(@alignCast(sc._fns[comptime opBase(Self) + @backingInt(op)]));
                return f(sc._states[slot], sc, arg);
            }
            const entry = sc._slots[slot];
            const vt: *const Vtable = @ptrCast(@alignCast(entry.vtable));
            const trampoline = @field(vt.*, name);
            return trampoline(entry.state, sc, arg);
        }

        pub fn store(sc: *Scope, comptime H: type, state: *anyopaque) void {
            const vt = comptime makeVtable(H);
            if (columns) {
                sc._states[slot] = state;
                inline for (op_names, 0..) |name, i| {
                    sc._fns[comptime opBase(Self) + i] = @ptrCast(@field(vt.*, name));
                }
            } else {
                sc._slots[slot] = .{ .state = state, .vtable = @ptrCast(vt) };
            }
        }
    };
}

// ── Scope — explicit effect scope ─────────────────────────────────────

/// Every slot starts as its own effect's typed panic stub, so no empty state
/// exists and exec needs no test at all.
const default_slots: [MAX_EFFECTS + 1]Slot = blk: {
    var out: [MAX_EFFECTS + 1]Slot = undefined;
    for (root.efx_effects, 1..) |T, i| out[i] = .{ .vtable = @ptrCast(&T.unbound) };
    break :blk out;
};
const default_fns: [total_ops]*const anyopaque = blk: {
    var out: [total_ops]*const anyopaque = undefined;
    var n: usize = 0;
    for (root.efx_effects) |T| {
        for (@typeInfo(T.Union).@"union".field_names) |name| {
            out[n] = @ptrCast(@field(T.unbound, name));
            n += 1;
        }
    }
    break :blk out;
};

pub const Scope = struct {
    _slots: if (columns) void else [MAX_EFFECTS + 1]Slot = if (columns) {} else default_slots,
    _states: if (columns) [MAX_EFFECTS + 1]*anyopaque else void = if (columns) undefined else {},
    _fns: if (columns) [total_ops]*const anyopaque else void = if (columns) default_fns else {},

    pub fn init(pairs: anytype) Scope {
        var self = Scope{};
        inline for (pairs) |pair| {
            pair[0].store(&self, HandlerType(@TypeOf(pair[1])), @ptrCast(pair[1]));
        }
        return self;
    }

    pub fn bind(self: *const Scope, comptime E: type, handler_ptr: anytype) Scope {
        var copy = self.*;
        E.store(&copy, HandlerType(@TypeOf(handler_ptr)), @ptrCast(handler_ptr));
        return copy;
    }
};

// ── View — a compile-time statement of which effects a function uses ──

/// Same bytes as Scope; only the type differs.
pub fn View(comptime effects: anytype) type {
    return struct {
        const Self = @This();
        scope: Scope,

        pub fn of(sc: *const Scope) *const Self {
            return @ptrCast(sc);
        }
        /// Free: every view has the whole-program layout.
        pub fn narrow(self: *const Self, comptime Sub: type) *const Sub {
            comptime Sub.assertSubsetOf(Self);
            return @ptrCast(self);
        }
        pub fn has(comptime E: type) bool {
            for (effects) |T| if (T == E) return true;
            return false;
        }
        pub fn assertSubsetOf(comptime Super: type) void {
            for (effects) |T| if (!Super.has(T)) @compileError("view does not provide " ++ @typeName(T));
        }
        pub inline fn exec(self: *const Self, comptime E: type, comptime op: anytype, arg: anytype) @TypeOf(E.exec(&self.scope, op, arg)) {
            if (comptime !has(E)) @compileError("effect not in this function's view: " ++ @typeName(E));
            return E.exec(&self.scope, op, arg);
        }
    };
}

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
            for (@typeInfo(Pairs).@"struct".field_types) |Pair| {
                const attrs = @typeInfo(Pair).@"struct".field_attrs[0];
                if (attrs.@"comptime" and attrs.defaultValue(type).? == E) return true;
            }
            return false;
        }
    };
}

// ── Exit — handler-directed early exit with a payload ────────────────

/// One-shot "abort" semantics on top of Zig error unions: a handler that
/// wants to stop the computation and deliver a result to the scope's
/// installer embeds an `Exit(T)`, calls `abort(value)`, and returns the
/// resulting `error.EfxAbort`. Business logic propagates it with `try`;
/// the installation site catches `error.EfxAbort` and reads `payload`.
///
/// Operations that may abort declare it in their result type:
///   check: efx.Op(u64, error{EfxAbort}!void)
///
/// Caveats: `error.EfxAbort` is one shared error value, so `payload` is only
/// meaningful for the Exit embedded in the handler *you* installed — with
/// multiple abort-capable handlers in a scope, check each one's payload.
/// Reset `payload` to null before reusing a handler across runs.
pub fn Exit(comptime T: type) type {
    if (@typeInfo(T) == .optional)
        @compileError("Exit(T) does not support optional T: abort(null) would be indistinguishable from 'never aborted'");
    return struct {
        payload: ?T = null,

        pub fn abort(self: *@This(), value: T) error{EfxAbort} {
            self.payload = value;
            return error.EfxAbort;
        }
    };
}

// ── Helpers ───────────────────────────────────────────────────────────

fn HandlerType(comptime PtrType: type) type {
    const info = @typeInfo(PtrType);
    if (info != .pointer) @compileError("Expected pointer to handler struct");
    if (info.pointer.attrs.@"const") @compileError("Handler must be a mutable pointer (*T), not *const T — declare handler with 'var'");
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

    pub fn info(self: *StderrLoggerHandler, _: []const u8) void {
        self.call_count += 1;
    }

    pub fn err(self: *StderrLoggerHandler, _: []const u8) void {
        self.call_count += 1;
    }
};

const AltLoggerHandler = struct {
    call_count: usize = 0,

    pub fn info(self: *AltLoggerHandler, _: []const u8) void {
        self.call_count += 1;
    }

    pub fn err(self: *AltLoggerHandler, _: []const u8) void {
        self.call_count += 1;
    }
};

const MapConfigHandler = struct {
    value: ?[]const u8 = null,

    pub fn get(self: *MapConfigHandler, _: []const u8) ?[]const u8 {
        return self.value;
    }
};
