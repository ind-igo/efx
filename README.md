# libfx

Tail-resumptive algebraic effects for Zig. Write programs as sequences of abstract operations and plug in different implementations without changing the logic. Handlers are plain structs. Dispatch is zero-cost. Gain testability for free.

Effects are a compositional primitive that allows you to model any boundary where you want to decouple logic from implementation:
- **Observability:** logging, metrics, tracing, feature flags. The original use case. Still the easiest way to get started. See `examples/logger.zig`.
- **Testing:** handler structs are the mocks, no framework needed. Capture calls and assert, inject faults, replay from a recorded trace, or run full deterministic simulation. See `examples/dst.zig`.
- **Data transformation:** validation, transformation, and enrichment as effects. Test each stage in isolation, swap backends without rewiring the pipeline. See `examples/pipeline.zig`.
- **Protocols:** consensus, replication, TLS handshakes. Write the protocol as effect calls, swap handlers for different backends or transports.
- **Storage engines:** block device, WAL, page cache as effects. Test B-tree logic against an in-memory handler. Inject write failures after N ops for crash recovery testing.
- **Networking:** transport, DNS, cert store as effects. Test a protocol state machine with loopback buffers and a virtual clock. No sockets, no timing jitter.

Additionally, libfx is designed to *compose* with Zig's IO interface. Rather than creating a full algebraic effect system with continuations, we create the simple tail-resumptive effects and design them to naturally compose with IO to create full algebraic effects. This natural synergy lets libfx be a tiny, focused ~220 line library that's easily extensible.

Inspired by [Effect.ts](https://effect.website) and algebraic effects research by Daan Leijen, specifically [Generalized Evidence Passing](https://www.microsoft.com/en-us/research/publication/generalized-evidence-passing-for-effect-handlers/) and [Implementing Algebraic Effects in C](https://www.microsoft.com/en-us/research/publication/implementing-algebraic-effects-c/).

## Example

```zig
const fx = @import("fx");

// Define an effect — a tagged union of operations
const Logger = fx.Effect(union(enum) {
    info: fx.Op([]const u8, void),
    err:  fx.Op([]const u8, void),
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

// Install and use
var logger = StderrLogger{};
fx.init(.{.{ Logger, &logger }});

Logger.exec(.info, "hello");  // dispatches through handler
```

Business logic calls `Logger.exec(.info, "starting")`. It doesn't know or care whether that goes to stderr, JSON, a test buffer, or /dev/null. Swap the handler, swap the behavior. The library validates at comptime that every operation has a matching handler method with the correct signature.

## Install

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .libfx = .{
        .url = "https://github.com/user/libfx/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Then in `build.zig`:

```zig
const fx = b.dependency("libfx", .{}).module("fx");
exe.root_module.addImport("fx", fx);
```

## Performance

Benchmarked on Apple Silicon (M-series), `ReleaseFast`, 100M iterations:

| Pattern | ns/op | ops/sec |
|---|---|---|
| Direct function call | 2.2 | 454M |
| Function pointer call | 2.2 | 454M |
| **Effect dispatch** | **2.1** | **465M** |
| 4 effects interleaving | 1.1 | 956M |
| 16 effects interleaving | 0.9 | 1063M |

The vtable pointer chase is fully hidden by the CPU. Vtables live in static `.rodata`, stay in L1, and dependent loads are overlapped by the branch predictor. Safe for hot-path use in performance-critical systems.

Run benchmarks yourself: `zig build bench`

## API

- **`fx.Effect(union(enum) { ... })`** — declare an effect as a tagged union of `fx.Op(Input, Output)` operations. Error unions work naturally.
- **`fx.init(.{ .{ Effect, &handler }, ... })`** — batch-install handlers at startup.
- **`Effect.exec(.op, arg)`** — dispatch an operation through the installed handler. Void args use `{}`.
- **`fx.set(Effect, &handler)`** — scoped override. Returns a token; restore with `defer fx.reset(token)`.
- **`fx.snapshot()` / `fx.restore(snap)`** — capture and propagate handlers across threads.

Handlers are plain structs with one method per operation. The library validates at comptime that every operation has a matching method with the correct signature. See the `examples/` folder for full usage.

## Testing

Effects are naturally testable — handler structs *are* the mocks:

```zig
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
    fx.init(.{.{ Logger, &log }});

    processOrder("order_99");

    try std.testing.expectEqualStrings("order_99", log.buf[0]);
}
```

## Internals

~220 lines. Threadlocal array of 16-byte slots (state pointer + vtable pointer), indexed by a runtime-assigned slot ID. Vtables are comptime-generated structs of typed trampolines — all type erasure is internal, users never see `*anyopaque`.
