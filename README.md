# efx

Tail-resumptive algebraic effects for Zig. Write programs as sequences of abstract operations and plug in different implementations without changing the logic. Handlers are plain structs. Dispatch is zero-cost. Everything is explicit.

Effects are a compositional primitive that allows you to model any boundary where you want to decouple logic from implementation:
- **Observability:** logging, metrics, tracing, feature flags. Still the easiest way to get started. See `examples/logger.zig`.
- **Testing:** handler structs are the mocks, no framework needed. Capture calls and assert, inject faults, replay from a recorded trace, or run full deterministic simulation. See `examples/dst.zig`.
- **Data transformation:** validation, transformation, and enrichment as effects. Test each stage in isolation, swap backends without rewiring the pipeline. See `examples/pipeline.zig`.
- **Protocols:** consensus, replication, TLS handshakes. Write the protocol as effect calls, swap handlers for different backends or transports.
- **Storage engines:** block device, WAL, page cache as effects. Test B-tree logic against an in-memory handler. Inject write failures after N ops for crash recovery testing.
- **Networking:** transport, DNS, cert store as effects. Test a protocol state machine with loopback buffers and a virtual clock. No sockets, no timing jitter.
- **Concurrency:** pass `*const Scope` to spawned threads — no snapshots or restore calls needed. See `examples/concurrent.zig`.

efx follows the same pattern as Zig's `std.Io` — an explicit capability value passed through the call stack. Rather than creating a full algebraic effect system with continuations, efx creates simple tail-resumptive effects designed to compose naturally with `std.Io` for full algebraic effects. This keeps it a focused ~250 line library.

Inspired by [Effect.ts](https://effect.website) and algebraic effects research by Daan Leijen, specifically [Generalized Evidence Passing](https://www.microsoft.com/en-us/research/publication/generalized-evidence-passing-for-effect-handlers/) and [Implementing Algebraic Effects in C](https://www.microsoft.com/en-us/research/publication/implementing-algebraic-effects-c/).

## Example

```zig
const std = @import("std");
const efx = @import("efx");

// Define an effect — a tagged union of operations
const Logger = efx.Effect(union(enum) {
    info: efx.Op([]const u8, void),
    err:  efx.Op([]const u8, void),
});

// Write a handler — a plain struct with matching methods
const StderrLogger = struct {
    pub fn info(_: *StderrLogger, msg: []const u8) void {
        std.debug.print("[INFO] {s}\n", .{msg});
    }
    pub fn err(_: *StderrLogger, msg: []const u8) void {
        std.debug.print("[ERR ] {s}\n", .{msg});
    }
};

// Create a scope and dispatch
var logger = StderrLogger{};
const scope = efx.Scope.init(.{.{ Logger, &logger }});

Logger.exec(&scope, .info, "hello");  // dispatches through handler
```

Business logic calls `Logger.exec(&scope, .info, "starting")`. It doesn't know or care whether that goes to stderr, JSON, a test buffer, or /dev/null. Swap the handler, swap the behavior. The library validates at comptime that every operation has a matching handler method with the correct signature.

## Install

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .efx = .{
        .url = "https://github.com/user/efx/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Then in `build.zig`:

```zig
const efx = b.dependency("efx", .{}).module("efx");
exe.root_module.addImport("efx", efx);
```

## Performance

Benchmarked on Apple Silicon (M-series), `ReleaseFast`, 100M iterations:

| Pattern | ns/op | ops/sec |
|---|---|---|
| Direct function call | 2.2 | 454M |
| Function pointer call | 2.2 | 454M |
| **Effect dispatch** | **2.3** | **441M** |
| 4 effects interleaving | 1.1 | 915M |
| 16 effects interleaving | 1.1 | 933M |

The vtable pointer chase is fully hidden by the CPU. Vtables live in static `.rodata`, stay in L1, and dependent loads are overlapped by the branch predictor. Safe for hot-path use in performance-critical systems.

Run benchmarks yourself: `zig build bench`

## API

- **`efx.Scope.init(.{ .{ Effect, &handler }, ... })`** — create a scope with handlers bound to effects.
- **`Effect.exec(&scope, .op, arg)`** — dispatch an operation through the scope's handler. Void args use `{}`.
- **`scope.bind(Effect, &handler)`** — return a new scope with one handler replaced. The original scope is unchanged.
- **`efx.Contract(.{ EffectA, EffectB, ... })`** — declare a required set of effects. The returned type has an `init` that works like `Scope.init` but produces a compile error if any listed effect is missing a handler. Useful when a library defines which effects it needs and consumers wire them up in a separate module. See `examples/pipeline.zig`.
- **`efx.Exit(T)`** — handler-directed early exit with a payload. The handler calls `exit.abort(value)` and returns `error.EfxAbort`; business logic propagates it with `try`; the installation site catches it and reads `exit.payload`. Since `error.EfxAbort` is one shared error value, `payload` is only meaningful for the handler you installed — with several abort-capable handlers in one scope, check each handler's payload after catching.

Dispatching an effect with no handler bound panics with a message naming the effect (use `Contract` to catch this at compile time instead).

Handlers may suspend: a handler that blocks on `std.Io.Queue` inside a coroutine turns a plain effect into a generator/stream — the caller's coroutine stack is the continuation. Call sites are unchanged. See `examples/generator.zig` and `docs/IO_COMPOSITION.md`.

Handlers are plain structs with one method per operation. Handlers that need to call other effects add `sc: *const efx.Scope` as a parameter — the library detects this at comptime and forwards the scope automatically:

```zig
const std = @import("std");

// Simple handler — no scope needed
const StderrLogger = struct {
    pub fn info(_: *StderrLogger, msg: []const u8) void {
        std.debug.print("[INFO] {s}\n", .{msg});
    }
};

// Composing handler — receives scope, calls other effects
const AuditLogger = struct {
    pub fn info(self: *AuditLogger, sc: *const efx.Scope, msg: []const u8) void {
        Metrics.exec(sc, .inc, "log.info");
        std.debug.print("[INFO] {s}\n", .{msg});
    }
};
```

For optional behavior, keep the effect in the contract and bind a no-op handler when the behavior is disabled. This keeps dispatch simple and fast: call sites always use `Effect.exec`, and handler choice decides whether anything happens.

```zig
const Metrics = efx.Effect(union(enum) {
    inc: efx.Op([]const u8, void),
});

const App = efx.Contract(.{ Logger, Metrics });

const NoopMetrics = struct {
    pub fn inc(_: *NoopMetrics, _: []const u8) void {}
};

var log = StderrLogger{};
var metrics = NoopMetrics{};
const scope = App.init(.{
    .{ Logger, &log },
    .{ Metrics, &metrics },
});

Metrics.exec(&scope, .inc, "requests"); // no-op unless a real handler is bound
```

See the `examples/` folder for full usage.

## Testing

Effects are naturally testable — handler structs *are* the mocks:

```zig
const std = @import("std");

const TestLogger = struct {
    buf: [64][]const u8 = undefined,
    len: usize = 0,

    pub fn info(self: *TestLogger, msg: []const u8) void {
        if (self.len < self.buf.len) { self.buf[self.len] = msg; self.len += 1; }
    }
    pub fn err(self: *TestLogger, msg: []const u8) void {
        if (self.len < self.buf.len) { self.buf[self.len] = msg; self.len += 1; }
    }
};

test "processOrder logs the order id" {
    var log = TestLogger{};
    const scope = efx.Scope.init(.{.{ Logger, &log }});

    processOrder(&scope, "order_99");

    try std.testing.expectEqualStrings("order_99", log.buf[0]);
}
```

## Internals

~250 lines. Stack-allocated scope containing an array of 16-byte slots (state pointer + vtable pointer), indexed by a runtime-assigned slot ID. Vtables are comptime-generated structs of typed trampolines — all type erasure is internal, users never see `*anyopaque`. No threadlocals, no hidden state. The scope is passed explicitly, like `std.mem.Allocator` or `std.Io`.
