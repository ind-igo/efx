# efx

Tail-resumptive algebraic effects for Zig. Write programs as sequences of abstract operations and plug in different implementations without changing the logic. Handlers are plain structs. Dispatch is one indirect call, about the cost of a hand-written vtable like `std.mem.Allocator`. Everything is explicit.

Effects are a compositional primitive that allows you to model any boundary where you want to decouple logic from implementation:
- **Observability:** logging, metrics, tracing, feature flags. Still the easiest way to get started. See `examples/logger.zig` and `examples/tracing.zig`.
- **Testing:** handler structs are the mocks, no framework needed. Capture calls and assert, inject faults, or run full deterministic simulation. See `examples/dst.zig`.
- **Protocols:** consensus, replication, handshakes. Drive the state machine through transport and clock effects, then test it with loopback buffers and a virtual clock: no sockets, no timing jitter. `examples/dst.zig` shows the approach on a small retry loop.
- **Storage engines:** block device, WAL, page cache as effects. Test against an in-memory handler and inject a crash at every operation. See `examples/storage.zig`.
- **Concurrency:** pass `*const Scope` to spawned tasks. Handlers shared between tasks must be thread-safe. See `examples/concurrent.zig`.

Effects suit real boundaries: I/O, time, randomness, anything you'd want to swap in a test. Pure logic such as validation or parsing is better left as plain functions. If a function needs one dependency, passing that dependency directly is simpler; `std.Random` and `std.mem.Allocator` are already swappable interfaces.

efx follows the same pattern as Zig's `std.Io` — an explicit capability value passed through the call stack. efx is not a full algebraic effect system: every handler returns to its caller, and there are no continuations to capture. `std.Io` does not add them, because a handler that blocks on `Io` is still just a blocking call. See `docs/IO_COMPOSITION.md`. This keeps efx a focused ~250 line library.

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

Requires Zig 0.17. Add it to your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/ind-igo/efx
```

Then in `build.zig`:

```zig
const efx = b.dependency("efx", .{}).module("efx");
exe.root_module.addImport("efx", efx);
```

## Performance

An effect call is an indirect call plus a slot lookup. Handlers cannot be inlined, so use effects at real boundaries. For tight loops, use comptime generics or pass a slice (see [Batch operations](#batch-operations)).

Apple M5 Pro, Zig 0.17, `ReleaseFast`. Median of 15 processes; predicted cases also sweep 16 code layouts. Overhead is relative to the same handler body inlined into the loop. Small handlers are three bodies of a few instructions each.

| Call kind | Overhead, predicted, small handler | Overhead, ~20-cycle handler | 16 random targets (total ns/op) |
|---|---|---|---|
| Comptime generic (inlined) | 0 ns | 0 ns | 6.5 (switch) |
| Direct call, not inlined | 0.3-0.5 ns | 0 ns | n/a |
| Hand-written vtable | 0.4-0.6 ns | 0 ns | 7.1 |
| **Effect dispatch** | **0.45-0.7 ns** | **0 ns** | **7.1** |

Without frame pointers the gaps are clearer: direct +0-0.25 ns, vtable +0.2 ns, effect +0.45-0.7 ns. That is about 0, 1 and 2-3 cycles, so a slot lookup costs a cycle or two more than a hand-written vtable. Treat sub-nanosecond differences as approximate: tight call loops on Apple Silicon run a whole number of cycles per iteration, and code layout alone can move a call by a cycle or more.

- Predicted calls overlap with surrounding work, so the cost disappears once a handler does real work.
- Unpredictable targets cost a branch mispredict, about 6 ns extra. This applies to any runtime dispatch, including a `switch`.
- With data caches cold, dispatch touches more cache lines than a direct call: about 5 ns more with L1D evicted, and roughly 60-80 ns more with L2 evicted.
- The optimizer cannot inline through `exec`, so loops lose vectorization and constant folding. A summing loop ran 6-10x slower than a comptime generic.
- A no-op handler still pays for dispatch.

Good fit: I/O, time, logging, storage and protocol boundaries. Poor fit: one effect call per element in a tight loop.

`zig build bench` runs one quick pass as raw CSV. `bench/run.sh` collects the numbers here; run it on an idle machine.

### Batch operations

An operation can take a slice. One dispatch then covers the whole batch, and the loop inside the handler compiles as an ordinary loop. A remote handler can also turn the batch into a single request.

```zig
const Lookup = struct { skus: []const u32, prices: []u32 };

const Prices = efx.Effect(union(enum) {
    lookup: efx.Op(Lookup, error{Unavailable}!void),
});

try Prices.exec(sc, .lookup, .{ .skus = skus, .prices = prices });
```

Summing 4096 `u32`s through the same effect, by batch size:

| Elements per dispatch | ns/element |
|---|---|
| 1 | 0.74 |
| 8 | 0.25 |
| 64 | 0.12 |
| 4096 | 0.11 |
| Comptime generic, for comparison | 0.11 |

See `examples/batch.zig`.

## API

- **`efx.Scope.init(.{ .{ Effect, &handler }, ... })`** — create a scope with handlers bound to effects.
- **`Effect.exec(&scope, .op, arg)`** — dispatch an operation through the scope's handler. Void args use `{}`.
- **`scope.bind(Effect, &handler)`** — return a new scope with one handler replaced. The original scope is unchanged.
- **`efx.Contract(.{ EffectA, EffectB, ... })`** — declare a required set of effects. The returned type has an `init` that works like `Scope.init` but produces a compile error if any listed effect is missing a handler. Useful when a library defines which effects it needs and consumers wire them up in a separate module. See `examples/storage.zig`.
- **`efx.Exit(T)`** — handler-directed early exit with a payload. The handler calls `exit.abort(value)` and returns `error.EfxAbort`; business logic propagates it with `try`; the installation site catches it and reads `exit.payload`. Since `error.EfxAbort` is one shared error value, `payload` is only meaningful for the handler you installed — with several abort-capable handlers in one scope, check each handler's payload after catching.

Dispatching an effect with no handler bound panics with a message naming the effect (use `Contract` to catch this at compile time instead).

Handlers may block: a handler that waits on `std.Io.Queue` turns a plain effect into a stream, and call sites are unchanged. The caller simply waits inside `exec`. The handler never holds a continuation. See `examples/generator.zig` and `docs/IO_COMPOSITION.md`.

Handlers are plain structs with one method per operation. Handlers that need to call other effects add `sc: *const efx.Scope` as a parameter — the library detects this at comptime and forwards the scope automatically (see `examples/tracing.zig`):

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

For optional behavior, keep the effect in the contract and bind a no-op handler when the behavior is disabled. This keeps call sites simple: they always use `Effect.exec`, and handler choice decides whether anything happens. A no-op handler still pays for dispatch.

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
