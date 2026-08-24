# efx + Io: One-Shot Effects by Composition

How efx's tail-resumptive evidence passing composes with Zig 0.16's `std.Io`
to get one-shot effect semantics without building a continuation runtime.

Working proof: `examples/generator.zig` (`zig build run-generator`).

## Theoretical Foundation

Based on Daan Leijen's work:
- "Implementing Algebraic Effects in C" (2017) — libhandler, setjmp/longjmp continuations
- "Generalized Evidence Passing for Effect Handlers" (2021) — evidence vectors, tail-resume optimization
- "Structured Asynchrony with Algebraic Effects" (2017) — async/await as effects

## The Three Layers

### Layer 1: Tail-resumptive (efx core)

The handler runs, returns a value, execution continues. No continuation
captured. Isomorphic to a virtual method call.

Covers: logging, config, metrics, DI, state, readers, tracing. The large
majority of real-world effects.

Implementation: `Scope` is the evidence vector — an array of
`(state, vtable)` slots, passed explicitly as `*const efx.Scope`.
O(1) dispatch, zero allocation.

### Layer 2: One-shot suspension (composition with Io)

The key fact: **with stackful coroutines, the caller's stack *is* the
continuation.** A handler that blocks inside a coroutine has implicitly
captured a one-shot continuation; unblocking is `resume(k, v)`. This is the
same trick that lets Go skip async/await.

So a suspending effect needs no new dispatch machinery — it is an ordinary
tail-resumptive effect whose *handler* blocks on `Io.Queue`:

```zig
const Source = efx.Effect(union(enum) {
    next: efx.Op(void, ?u64),
});

// From the caller's coroutine: perform → suspend → resume with a value.
const StreamSource = struct {
    io: std.Io,
    queue: *std.Io.Queue(u64),

    pub fn next(self: *StreamSource) ?u64 {
        return self.queue.getOne(self.io) catch null; // SUSPENDS here
    }
};
```

Call sites stay abstract (`Source.exec(&sc, .next, {})`), so the
swap-the-handler property holds across layers: bind a pure in-memory handler
in tests, an Io-backed one in production. The suspension is an implementation
detail of the handler, invisible to business logic.

Covers: generators/streams, cooperative scheduling, rendezvous, actors.

### Layer 3: Multi-shot continuations (not supported)

Resuming a continuation multiple times requires stack copying. Not supported,
rarely needed — Leijen notes almost all real effects are tail-resumptive or
one-shot.

## Handler-Directed Exit (`efx.Exit`)

A real algebraic handler can discard the continuation and return a value to
its installation point (exceptions, early exit). `exec` must return to the
caller, so efx maps this onto Zig's error unions: `efx.Exit(T)` carries a
payload, the handler returns `error.EfxAbort`, business logic propagates it
with `try`, and the installer catches it and reads the payload. See the
"Exit delivers a payload to the installer" test in `src/efx.zig`.

This is one-shot *abort* semantics built on unwinding Zig already has —
not handler-directed control transfer in the general sense.

## Evidence Passing: Leijen → efx Mapping

| Leijen (evidence passing)    | efx                                  |
|------------------------------|----------------------------------------|
| Evidence vector `w`          | `Scope._slots[MAX_EFFECTS]`            |
| Evidence entry `(m, ops)`    | `Slot { .state, .vtable }`             |
| Handler marker `m`           | `.state: *anyopaque` (handler struct)  |
| Operation functions `ops`    | `.vtable` (comptime-generated)         |
| `perform op(x)` tail-resume  | `E.exec(&sc, .op, x)` — vtable call    |
| Evidence threading           | Explicit `*const Scope` parameter      |
| Handler frame push/pop       | `scope.bind` (value copy, lexical)     |

Leijen passes evidence as a hidden parameter; efx passes it explicitly,
the same convention as `std.Io` and `Allocator`. Same semantics, visible
plumbing.

## Crossing Io Boundaries

`Scope` is a plain value with no thread affinity. Pass `*const Scope` (or a
copy) into `io.concurrent` like any other argument — no snapshot/restore
step exists or is needed. See `examples/concurrent.zig`.

```zig
var task = try io.concurrent(worker, .{ &sc, arg });
```

The scope must outlive the task, same as any borrowed pointer.

## What Leijen Builds vs What We Reuse

| Component                  | Leijen (libhandler, ~3000 LOC C) | efx + Io             |
|----------------------------|----------------------------------|------------------------|
| Evidence vectors           | Custom                           | `Scope` (~60 LOC)      |
| Handler stack              | Linked list of frames            | `bind` (value copy)    |
| Yield frames               | Custom struct + chain            | `Io.Queue(T)` (stdlib) |
| setjmp/longjmp machinery   | Custom                           | Io coroutines (stdlib) |
| Stack segment management   | Custom                           | Io manages (stdlib)    |
| Stack copying (multi-shot) | Custom memcpy                    | Not supported          |
| Abort to handler           | longjmp                          | `efx.Exit` + error union |

Neither library knows about the other. efx manages WHAT ambient context is
available (evidence); Io manages HOW concurrent work is scheduled
(continuations). They compose because the layers are orthogonal.

## Building a Runtime on efx + Io

The runtime is not a framework — it is a *wiring convention*. `main()` owns
the `Io`, handlers own their slice of it, and business logic sees only
`*const Scope`.

### The boundary rule

**Io never crosses the effect boundary.** Business logic takes `*const Scope`
and nothing else; any handler that needs to sleep, spawn, read a socket, or
block on a queue captures `io` as a field at construction time
(`examples/generator.zig`'s `StreamSource` is the template). Two payoffs:

1. **Determinism for free.** The test build binds pure handlers and needs no
   Io at all — no virtual event loop, no mock scheduler. Your DST story is
   "same Contract, different pairs".
2. **One signature everywhere.** No `fn f(io: Io, sc: *const Scope, ...)`
   double-threading through every call. The only functions that take `Io`
   are handler constructors and `main`.

### Runtime skeleton

```zig
// 1. Declare the world as a Contract — this IS the runtime's interface.
const Runtime = efx.Contract(.{ Clock, Log, Net, Storage, Tasks });

// 2. Production wiring: main owns Io, handlers embed it.
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var clock   = IoClock{ .io = io };
    var log     = StderrLog{};
    var net     = IoNet{ .io = io };
    var storage = FileStorage{ .io = io, .dir = ... };
    var tasks   = IoTasks{ .io = io, .group = .init };

    const sc = Runtime.init(.{
        .{ Clock, &clock }, .{ Log, &log }, .{ Net, &net },
        .{ Storage, &storage }, .{ Tasks, &tasks },
    });

    try program(&sc); // business logic: Scope only, no Io in sight
}

// 3. Test wiring: same Contract, zero Io.
test {
    var clock = VirtualClock{ .now = 0 };
    var log   = CaptureLog{};
    // ... pure handlers ...
    const sc = Runtime.init(.{ ... });
    try program(&sc);
}
```

### Rules of thumb

- **One root scope, `bind` for overrides.** Build the full scope once at
  startup; subsystems that need a different handler (request-scoped tracer,
  fault-injecting storage) take a `bind`ed copy. Scopes are 256-byte values —
  copying is the mechanism, not a cost to avoid.
- **Suspending ops return `Cancelable!T`.** Any operation whose handler may
  block on Io must surface `error.Canceled` in its result type so
  cancellation propagates through business logic via `try`
  (see `Source.next` in `examples/generator.zig`). An op with a bare return
  type is a promise that its handler never suspends cancelably.
- **Spawning stays at the Io layer.** `io.concurrent` is generic over the
  spawned function's type; `Op(Arg, Result)` is monomorphic, so "spawn
  anything" cannot be an effect. Either keep structured concurrency in the
  layer that owns `Io` (main, actors, supervisors), or expose *specific*
  spawns as ops (`start_worker: Op(WorkerConfig, WorkerId)`) handled by a
  struct that owns an `Io.Group`.
- **Actors are the composition unit.** An actor = `io.concurrent` coroutine +
  `Io.Queue(Msg)` mailbox + a `*const Scope` passed in at spawn. The scope
  gives every actor ambient context (log, clock, metrics) without globals;
  the mailbox gives it one-shot suspension. Supervision is a loop that
  re-spawns on error return.
- **Scope lifetime = task lifetime.** A scope passed to a coroutine is a
  borrowed pointer; either keep it alive past `Group.await`/`Future.await`
  (the normal case — it lives in `main`), or pass a copy by value into the
  spawned function's args.

### Runtime compatibility

efx composes against the `std.Io` *interface*, not a particular event
loop. Anything that implements the `Io` vtable slots into the same handler
pattern unchanged:

| Runtime                        | Integration                                          |
|--------------------------------|------------------------------------------------------|
| `std.Io` (io_uring/kqueue)     | Handlers hold `io` — the patterns above as written   |
| `std.Io.Threaded`              | Same code; suspension = OS thread blocking (slower)  |
| [zio](https://github.com/lalinsky/zio) | Implements `std.Io` (0.16+) — handlers work as-is; its native channels/groups can back handlers directly for cheaper fibers |
| Callback runtimes (libxev)     | Layer 1 only — no coroutine stack means no implicit continuation; suspending handlers need a state-machine rewrite |

The requirement for one-shot suspension is stackful coroutines — a blocked
handler must implicitly capture the caller's stack. Fibers may migrate
across OS threads; `Scope` is a plain immutable value with no thread
affinity, so this is safe as long as the scope outlives the task group.

## Honest Limits

- **No handler-directed control transfer.** Handlers cannot redirect
  execution anywhere except back to the caller (normal return) or up the
  error path (`efx.Exit`). Full `ctl` operations are out of scope.
- **No effect rows.** A function taking `*const Scope` may perform any
  effect; missing handlers panic at dispatch (`exec` checks), they are not
  compile errors at call sites. `efx.Contract` checks completeness at the
  wiring site only.
- **`std.Io` is young.** Validated against Zig 0.16.0. The
  `concurrent`/`Queue`/`Future` surface may still change.
