# efu: Tail-Resumptive Effects for Zig

A Zig library for dynamically-scoped ambient context through algebraic effects, restricted to the tail-resumptive subset. Complements Zig's `Io` and explicit allocator passing — resources with ownership stay explicit, ambient operational context goes through effects.

## Core Concepts

**Tail-resumptive only.** Operations resume exactly once, in tail position. No continuations, no stack capture, no setjmp/longjmp. Covers: state, readers, writers, loggers, metrics, tracing, config, dependency injection.

**Reified effects.** Operations are tagged union variants. Handlers are structs with one method per operation. Exhaustiveness is verified at comptime.

**Comptime-generated dispatch.** Effect declarations produce type-safe operation wrappers via metaprogramming. Type erasure is fully internal via comptime-generated trampolines — users never see `*anyopaque`.

**Thread-local handler stack.** Bounded threadlocal array. Push on enter, pop on exit with `defer`. No allocation in the dispatch path.

## API

### Declaring an Effect

Pass a tagged union to `Effect()`. Each variant is an operation. Use `efu.Op` to declare the argument type and optional return type for each variant.

```zig
const efu = @import("efu");

// void-returning operations — Op with one type param defaults return to void
pub const Logger = efu.Effect(union(enum) {
    info: efu.Op([]const u8),
    err: efu.Op([]const u8),
});

// Operations with return types — Op(ArgType, ReturnType)
pub const Config = efu.Effect(union(enum) {
    get: efu.Op([]const u8, ?[]const u8),
    get_int: efu.Op([]const u8, ?i64),
});

// Multiple arguments — use a struct as the arg type
pub const Tracing = efu.Effect(union(enum) {
    start_span: efu.Op(struct { name: []const u8, parent: ?u64 = null }, u64),
    end_span: efu.Op(u64),
});
```

`Effect()` returns a type containing:
- `Op` — the operation union (with `efu.Op` wrappers stripped, handlers see arg types directly)
- `id` — unique comptime identifier (static address, integer comparison)
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

`efu.init` installs handlers onto the thread-local stack. `deinit` removes them. Use `defer` for safety.

```zig
pub fn main() !void {
    var logger = StderrLogger{ .writer = std.io.getStdErr().writer().any() };
    var metrics = PrometheusMetrics{ ... };

    const effects = efu.init(.{
        .{ Logger, &logger },
        .{ Metrics, &metrics },
    });
    defer effects.deinit();

    Logger.info("starting");
    try run();
}
```

Handlers are popped in reverse order on `deinit`. Defers guarantee cleanup on all exit paths — normal return, error return, or panic.

### Error Propagation

The `Result` type flows through dispatch unchanged. If an effect declares an error union as its result, callers use `try` normally:

```zig
pub const Database = efu.Effect(union(enum) {
    query: efu.Op([]const u8, anyerror![]Row),
});

// At the call site:
const rows = try Database.query("SELECT * FROM users");
```

The generated dispatch wrapper and trampoline pass the `Result` type through at comptime. No wrapping, no special handling. Zig's error inference works through effect calls because the return type is determined statically by the `Result` mapping.

### Missing Handler Behavior

If no handler is found for an effect, dispatch panics with a descriptive message naming the effect and call site. This is a programming error — same category as null unwrap or out-of-bounds access.

### Handler Stack Overflow

If the handler stack exceeds `MAX_HANDLERS` (default 64), `init` panics with a message reporting the current depth. Same philosophy — a programming error, not a recoverable condition.

## Handler Stack

```zig
const MAX_HANDLERS = 64;

const HandlerEntry = struct {
    effect_id: usize,
    state: *anyopaque,
    vtable: *const anyopaque,  // points to comptime-generated static array of trampolines
};

threadlocal var handler_stack: [MAX_HANDLERS]HandlerEntry = undefined;
threadlocal var handler_stack_len: usize = 0;
```

Each handler entry is 24 bytes. 64 entries = 1,536 bytes of threadlocal storage.

Dispatch walks top-down, finds the first match for the effect's id, loads the vtable pointer, and calls the trampoline at the index corresponding to the operation variant (known at comptime).

## Type Erasure via Vtables

When `init` is called, the library generates a vtable at comptime for each handler:

1. Walks the effect's operation variants.
2. For each operation, finds the matching method on the handler struct and verifies its signature. Missing or mismatched methods are compile errors.
3. Generates a trampoline per operation that casts `*anyopaque` back to the concrete handler type and calls the method.
4. Lays out all trampolines in a static array (the vtable). One vtable per handler-for-an-effect, stored in read-only memory, shared across threads.
5. The handler stack entry stores a pointer to this vtable.

Users write typed methods on plain structs. All `@ptrCast`/`@alignCast` is internal to the library. At dispatch time, the cost is: stack walk + one pointer load (vtable) + indexed call into the vtable.

## Bind

`bind()` walks the handler stack once and returns a `Bound` instance with a direct function pointer. Subsequent calls bypass the stack walk entirely.

```zig
fn hotLoop(data: []const u8) void {
    const log = Logger.bind();
    for (data) |_| {
        log.info("processing");  // direct call, ~1.5ns
    }
}
```

`tryBind()` returns an optional for graceful degradation.

**Lifetime rules:** a `Bound` instance is valid only within the scope of the handler it captured. Do not store across handler boundaries, return from functions, or pass across task boundaries.

## Module Structure

```
src/
├── efu.zig         // Public API re-exports
├── effect.zig      // Effect(), Op(), dispatch wrappers
├── handler.zig     // init(), deinit(), handler stack
└── bind.zig        // bind(), tryBind(), Bound type
```

## Performance Targets

- Handler dispatch: ~20ns (stack walk + trampoline + switch)
- Bind dispatch: ~1.5ns (direct call through captured pointer)
- Handler init/deinit: ~5ns per handler
- Zero allocations in the dispatch path

## Non-Goals

- Multi-shot continuations
- Stack capture
- Effect tracking in the type system
- Replacing `Io` or `Allocator`
- A full async runtime
- Standard effect implementations (users define their own)
- Combinators (users compose with normal Zig code)
