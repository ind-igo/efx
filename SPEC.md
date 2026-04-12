# libfx: Tail-Resumptive Effects for Zig

A Zig library for dynamically-scoped ambient context through algebraic effects, restricted to the tail-resumptive subset. Complements Zig's `Io` and explicit allocator passing — resources with ownership stay explicit, ambient operational context goes through effects.

## Core Concepts

**Tail-resumptive only.** Operations resume exactly once, in tail position. No continuations, no stack capture, no setjmp/longjmp. Covers: state, readers, writers, loggers, metrics, tracing, config, dependency injection.

**Reified effects.** Operations are tagged union variants. Handlers are structs with one method per operation. Exhaustiveness is verified at comptime.

**Comptime-generated dispatch.** Effect declarations produce type-safe operation wrappers via metaprogramming. Type erasure is fully internal via comptime-generated trampolines — users never see `*anyopaque`.

**Thread-local effect slots.** Direct-indexed threadlocal arrays keyed by comptime effect ID. O(1) dispatch with no search. No allocation in the dispatch path.

## API

### Declaring an Effect

Pass a tagged union to `Effect()`. Each variant is an operation. Use `fx.Op` to declare the argument type and optional return type for each variant.

```zig
const fx = @import("libfx");

// void-returning operations — Op with one type param defaults return to void
pub const Logger = fx.Effect(union(enum) {
    info: fx.Op([]const u8),
    err: fx.Op([]const u8),
});

// Operations with return types — Op(ArgType, ReturnType)
pub const Config = fx.Effect(union(enum) {
    get: fx.Op([]const u8, ?[]const u8),
    get_int: fx.Op([]const u8, ?i64),
});

// Multiple arguments — use a struct as the arg type
pub const Tracing = fx.Effect(union(enum) {
    start_span: fx.Op(struct { name: []const u8, parent: ?u64 = null }, u64),
    end_span: fx.Op(u64),
});
```

`Effect()` returns a type containing:
- `Op` — the operation union (with `fx.Op` wrappers stripped, handlers see arg types directly)
- `slot` — runtime-assigned index into the effect slot arrays. Assigned once on first `init` or `set` call via a global counter. Write-once, then read forever. Used as a direct array index for O(1) dispatch.
- One dispatch wrapper per variant: `Logger.info("msg")`, `Config.get("KEY")`

### Writing a Handler

A handler is a struct with one method per operation. Each method takes `*Self` and the operation's arg type, and returns the operation's return type. The library validates at comptime that every operation has a matching method with the correct signature — missing or mismatched methods are compile errors.

```zig
const StderrLogger = struct {
    writer: std.io.AnyWriter,

    fn info(self: *StderrLogger, msg: []const u8) void {
        self.writer.print("[INFO] {s}\n", .{msg}) catch {};
    }

    fn err(self: *StderrLogger, msg: []const u8) void {
        self.writer.print("[ERR ] {s}\n", .{msg}) catch {};
    }
};
```

Handlers with return types have natural signatures:

```zig
const MapConfig = struct {
    map: std.StringHashMap([]const u8),

    fn get(self: *MapConfig, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    fn get_int(self: *MapConfig, key: []const u8) ?i64 {
        const val = self.map.get(key) orelse return null;
        return std.fmt.parseInt(i64, val, 10) catch null;
    }
};
```

Handlers that need scratch allocation own it in their state:

```zig
const JsonLogger = struct {
    writer: std.io.AnyWriter,
    arena: std.heap.ArenaAllocator,

    fn info(self: *JsonLogger, msg: []const u8) void {
        defer _ = self.arena.reset(.retain_capacity);
        const formatted = std.fmt.allocPrint(
            self.arena.allocator(),
            "{{\"level\":\"info\",\"msg\":\"{s}\"}}\n",
            .{msg},
        ) catch return;
        self.writer.writeAll(formatted) catch {};
    }

    fn err(self: *JsonLogger, msg: []const u8) void {
        defer _ = self.arena.reset(.retain_capacity);
        // ...
    }
};
```

### Installing Handlers

Three functions: `init`, `set`, `reset`.

**`init`** — batch install, used at startup. Assigns slot IDs on first use. Fire and forget.

```zig
pub fn main() !void {
    var logger = StderrLogger{ .writer = std.io.getStdErr().writer().any() };
    var config = EnvConfig{};

    fx.init(.{
        .{ Logger, &logger },
        .{ Config, &config },
    });

    Logger.info("starting");
    try run();
}
```

**`set`** — swap a single effect's handler, returns a token capturing the previous state.

**`reset`** — restore a previous handler from a token. Pair with `defer` for scoped swaps.

```zig
fn handleRequest(req: Request) void {
    var req_logger = RequestLogger{ .request_id = req.id };
    const prev = fx.set(Logger, &req_logger);
    defer fx.reset(prev);

    // req_logger active here
    processOrder(req.order_id);
}
// previous Logger restored on scope exit
```

### Error Propagation

The `Result` type flows through dispatch unchanged. If an effect declares an error union as its result, callers use `try` normally:

```zig
pub const FeatureFlags = fx.Effect(union(enum) {
    is_enabled: fx.Op([]const u8, anyerror!bool),
});

// Handler method returns the error union directly:
const RemoteFlags = struct {
    client: *http.Client,
    base_url: []const u8,

    fn is_enabled(self: *RemoteFlags, flag: []const u8) anyerror!bool {
        const response = try self.client.get(self.base_url, flag);
        return std.mem.eql(u8, response.body, "true");
    }
};

// At the call site:
const dark_mode = try FeatureFlags.is_enabled("dark_mode");
```

The generated dispatch wrapper and trampoline pass the return type through at comptime. No wrapping, no special handling. Zig's error inference works through effect calls because the return type is determined statically from the `fx.Op` declaration.

### Missing Handler Behavior

If no handler is found for an effect, dispatch panics with a descriptive message naming the effect and call site. This is a programming error — same category as null unwrap or out-of-bounds access.

### Handler Slot Overflow

If the number of distinct effects exceeds `MAX_EFFECTS` (default 32, configurable via build option), `init` or `set` panics at runtime.

## Effect Slots

Effects are stored in direct-indexed parallel arrays, keyed by a runtime-assigned slot index:

```zig
const UNASSIGNED = std.math.maxInt(usize);
const MAX_EFFECTS = 32;

var next_slot: usize = 0;  // global, atomically incremented on first use of each effect

threadlocal var states: [MAX_EFFECTS]*anyopaque = undefined;
threadlocal var vtables: [MAX_EFFECTS]*const anyopaque = undefined;
threadlocal var installed: [MAX_EFFECTS]bool = .{false} ** MAX_EFFECTS;
```

Each `Effect()` type has a static `var slot: usize = UNASSIGNED`. On first `init` or `set`, the slot is assigned atomically:

```zig
fn ensureSlot() usize {
    const current = @atomicLoad(usize, &slot, .acquire);
    if (current != UNASSIGNED) return current;

    const new_slot = @atomicRmw(usize, &next_slot, .Add, 1, .acq_rel);
    if (new_slot >= MAX_EFFECTS) @panic("too many effects");

    // If another thread already assigned, use theirs
    return @cmpxchgStrong(usize, &slot, UNASSIGNED, new_slot, .acq_rel, .acquire) orelse new_slot;
}
```

Slot assignment is thread-safe and happens exactly once per effect type. After assignment, `slot` is effectively a constant — every subsequent read is a plain load with no contention. The atomics only fire on first use.

Total threadlocal storage: `MAX_EFFECTS * 17` bytes (default 544 bytes). No search — dispatch indexes directly by slot.

### Dispatch Path

For `Logger.info("msg")`:
1. Load `Logger.slot` — a global read (write-once, effectively constant after init).
2. Load `states[slot]` and `vtables[slot]` — two threadlocal array loads, O(1).
3. Index into the vtable by the operation's comptime variant index.
4. Call the trampoline with state and arg.

No linear search. Dispatch cost is three loads plus the vtable call.

### Thread Behavior

Effect slots are threadlocal. New threads start with empty slots — effects must be explicitly installed per thread. This is consistent with Zig's explicit-over-implicit philosophy.

## Type Erasure via Vtables

When `init` or `set` is called, the library generates a vtable at comptime for each handler:

1. Walks the effect's operation variants.
2. For each operation, finds the matching method on the handler struct and verifies its signature. Missing or mismatched methods are compile errors.
3. Generates a trampoline per operation that casts `*anyopaque` back to the concrete handler type and calls the method.
4. Lays out all trampolines in a static array (the vtable). One vtable per handler-for-an-effect, stored in read-only memory, shared across threads.
5. The vtable pointer is stored in `vtables[E.slot]` alongside the state in `states[E.slot]`.

Users write typed methods on plain structs. All `@ptrCast`/`@alignCast` is internal to the library. At dispatch time, the cost is: one global load (slot) + two threadlocal array loads (state + vtable) + indexed call into the vtable.

## Module Structure

Single file: `src/libfx.zig`. The library is ~300-400 lines — small enough that splitting would add complexity without aiding navigation.

## Performance Targets

- Handler dispatch: ~5ns (direct array index + vtable call, no search)
- Handler init/set/reset: ~5ns per effect
- Zero allocations in the dispatch path

## Non-Goals

- Multi-shot continuations
- Stack capture
- Effect tracking in the type system
- Replacing `Io` or `Allocator`
- A full async runtime
- Standard effect implementations (users define their own)
- Combinators (users compose with normal Zig code)
