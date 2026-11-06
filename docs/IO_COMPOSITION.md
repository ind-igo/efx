# efx and `std.Io`

efx provides tail-resumptive effects: a handler runs, returns a value, and
execution continues. `std.Io` provides OS operations and concurrency. The two
work well side by side, but combining them does not produce full algebraic
effects. This document covers what each one does, what you get by combining
them, and what you don't.

## Theoretical Foundation

Based on Daan Leijen's work:
- "Implementing Algebraic Effects in C" (2017) — libhandler, setjmp/longjmp continuations
- "Generalized Evidence Passing for Effect Handlers" (2021) — evidence vectors, tail-resume optimization
- "Structured Asynchrony with Algebraic Effects" (2017) — async/await as effects

## What efx Provides

No continuation is captured, so an effect call is isomorphic to a virtual
method call. That covers logging, config, metrics, dependency injection, state
and tracing, plus any boundary you want to swap in a test.

`Scope` is the evidence vector: an array of `(state, vtable)` slots, passed
explicitly as `*const efx.Scope`.

| Leijen (evidence passing)    | efx                                    |
|------------------------------|----------------------------------------|
| Evidence vector `w`          | `Scope._slots`                         |
| Evidence entry `(m, ops)`    | `Slot { .state, .vtable }`             |
| Handler marker `m`           | `.state: *anyopaque` (handler struct)  |
| Operation functions `ops`    | `.vtable` (comptime-generated)         |
| `perform op(x)` tail-resume  | `E.exec(&sc, .op, x)` — vtable call    |
| Evidence threading           | Explicit `*const Scope` parameter      |
| Handler frame push/pop       | `scope.bind` (value copy, lexical)     |

Leijen passes evidence as a hidden parameter; efx passes it explicitly, the
same convention as `std.Io` and `Allocator`.

## Where `std.Io` Overlaps

`std.Io` is itself a swappable interface, and its vtable now covers time,
randomness, files, networking, futexes and concurrency. For those operations,
use `Io` directly unless you need something it doesn't give you.

efx earns its place in two situations:

- **Application vocabulary.** `Io` speaks in files and sockets. Effects like
  `Upstream`, `Disk` or `Metrics` speak in your program's terms, so a test can
  fail one upstream call without faking a socket. See `examples/dst.zig`.
- **Swapping one operation in one subtree.** `scope.bind` replaces a single
  effect for one call tree. Faking only `now` in `Io` means copying the whole
  vtable, and because `userdata` must remain the real `Threaded` instance, the
  fake's state ends up global. See `CrashAfter` in `examples/storage.zig`.

## Blocking Handlers

A handler can capture `io` and block. The effect stays an ordinary effect, and
the caller waits inside `exec`:

```zig
const Source = efx.Effect(union(enum) {
    next: efx.Op(void, std.Io.Cancelable!?u64),
});

const StreamSource = struct {
    io: std.Io,
    queue: *std.Io.Queue(u64),

    pub fn next(self: *StreamSource) std.Io.Cancelable!?u64 {
        return self.queue.getOne(self.io) catch |e| switch (e) { // blocks here
            error.Closed => null,
            error.Canceled => error.Canceled,
        };
    }
};
```

Call sites stay abstract (`Source.exec(&sc, .next, {})`), so you can bind a pure
in-memory handler in tests and an Io-backed one in production. See
`examples/generator.zig`.

This needs an `Io` implementation that keeps the blocked call's stack, either
with threads or with stackful fibers. On `std.Io.Threaded`, the implementation
tested here, a blocked handler blocks an OS thread. `std.Io.Evented` does not
compile on macOS in Zig 0.17.0, so blocking handlers are untested on it.

## What This Does Not Give You

Blocking is not a captured continuation. The blocked stack belongs to `Io`. The
handler cannot name it, store it, or decide what happens next: another task has
to fill the queue, and the handler then returns like any other.

| Capability                                | Full effect handlers | efx + `Io`                                    |
|-------------------------------------------|----------------------|-----------------------------------------------|
| Receive the continuation as a value       | Yes                  | No                                            |
| Run handler code after resuming           | Yes                  | No, returning is the resume                   |
| Keep a continuation and resume it later   | Yes                  | Only by blocking until another task signals   |
| Abort the computation                     | Yes                  | `efx.Exit`, through ordinary error returns    |
| Resume more than once                     | With multi-shot      | No                                            |

Full handlers need something that owns the computation's stack and gives the
handler a resumable value. `std.Io` does not expose one as an effect primitive,
so the separate `efx_cont` module provides it.

## Continuations (`efx_cont`)

`efx_cont` is a fixed pool of stacks with one-shot continuations. It adds what
the table above is missing and nothing else: no scheduler, and no I/O. efx and
`efx_cont` don't import each other, because a handler is a plain struct:

```zig
const Store = efx.Effect(union(enum) {
    get: efx.Op(u64, std.Io.Cancelable!u64),
});

const P = efx_cont.Pool(.{ .Request = u64, .Reply = u64 });

const Parking = struct {
    pool: *P,

    pub fn get(self: *Parking, key: u64) std.Io.Cancelable!u64 {
        return self.pool.perform(key); // appends a row, then parks
    }
};
```

Business logic can't tell this handler from one that returns at once, or one
that blocks on `Io`: all three use the same `Op`. Whoever owns the pool drives
it on its own stack, which is also where its I/O belongs:

```zig
try pool.spawn(worker, .{ &sc, 7 });
while (pool.live() != 0) {
    pool.tick();
    const batch = pool.take();
    for (batch.requests, batch.conts) |request, k| {
        try pool.complete(k, try lookup(io, request));
    }
}
```

A handler that wants the continuation for itself keeps it before parking:

```zig
self.timers.add(deadline, self.pool.continuation());
return self.pool.park();
```

| Capability                              | `efx_cont`                                   |
|-----------------------------------------|----------------------------------------------|
| Receive the continuation as a value     | `continuation()`, or the `conts` of a batch  |
| Run handler code after resuming         | Yes, after `park` returns                    |
| Keep a continuation and resume it later | `complete(k, value)`, from any point         |
| Abort the computation                   | `cancel(k)`: `error.Canceled`, `defer`s run  |
| Resume more than once                   | No: a second resume is `StaleContinuation`   |

- **The handler chooses, not the effect.** An `Op` doesn't say whether it parks,
  so a test can bind a handler that returns at once.
- **Nothing is dropped.** `deinit` cancels every live computation, so `defer`s run
  even if the driver stops early. A `perform` during that cleanup gets
  `error.Canceled`, so a `defer` can't wait on real work at shutdown. End the pool
  before the handlers its computations use.
- **State follows the scope.** A handler bound before `spawn` is shared by every
  computation given that scope. One bound inside a computation is its own.
- **One thread at a time.** A pool has no locks. Another thread hands a result to
  the driver, and the driver calls `complete`.
- **Stacks are a fixed size.** Running past the end faults on a guard page.

## Handler-Directed Exit (`efx.Exit`)

A real algebraic handler can discard the continuation and return a value to
its installation point (exceptions, early exit). `exec` must return to the
caller, so efx maps this onto Zig's error unions: `efx.Exit(T)` carries a
payload, the handler returns `error.EfxAbort`, business logic propagates it
with `try`, and the installer catches it and reads the payload. See the
"Exit delivers a payload to the installer" test in `src/efx.zig`.

This is abort built on unwinding Zig already has, not general control transfer.
A caller that catches the error instead of propagating it keeps running.

## Crossing Io Boundaries

`Scope` is a plain value with no thread affinity. Pass `*const Scope` (or a
copy) into `io.concurrent` like any other argument. Handlers reachable from
concurrent tasks must be thread-safe. See `examples/concurrent.zig`.

```zig
var task = try io.concurrent(worker, .{ &sc, arg });
```

The scope must outlive the task, same as any borrowed pointer.

## Wiring a Program

`main()` owns the `Io`, handlers that need it capture it as a field, and logic
that only needs your effects takes `*const Scope`:

```zig
// 1. Declare what the program needs from the outside world.
const App = efx.Contract(.{ Upstream, Disk, Metrics });

// 2. Production wiring: handlers capture what they need.
pub fn main(init: std.process.Init) !void {
    var upstream = HttpUpstream{ .io = init.io };
    var disk = FileDisk{ .io = init.io };
    var metrics = StatsdMetrics{ .io = init.io };

    const sc = App.init(.{
        .{ Upstream, &upstream }, .{ Disk, &disk }, .{ Metrics, &metrics },
    });

    try program(&sc);
}

// 3. Test wiring: same Contract, pure handlers, no Io.
test {
    var upstream = FlakyUpstream{ .seed = 42 };
    var disk = MemDisk{};
    var metrics = CaptureMetrics{};
    const sc = App.init(.{ ... });
    try program(&sc);
}
```

Code that genuinely works with files or sockets can take `io` directly.

### Rules of thumb

- **One root scope, `bind` for overrides.** Build the full scope once at
  startup; subsystems that need a different handler take a `bind`ed copy. A
  default scope is a 256-byte value, so copying it is cheap.
- **Blocking ops return `Cancelable!T`.** Any operation whose handler may block
  on Io should surface `error.Canceled` in its result type so cancellation
  propagates through business logic via `try`. See `Source.next` in
  `examples/generator.zig`.
- **Spawning stays at the Io layer.** `io.concurrent` is generic over the
  spawned function's type; `Op(Arg, Result)` is monomorphic, so "spawn anything"
  cannot be an effect. Either keep structured concurrency in the layer that owns
  `Io`, or expose specific spawns as ops (`start_worker: Op(WorkerConfig, WorkerId)`)
  handled by a struct that owns an `Io.Group`.
- **Scope lifetime covers task lifetime.** Keep a scope alive past
  `Group.await`/`Future.await` (the normal case, since it lives in `main`), or
  pass a copy by value into the spawned function's args.

## Limits

- **One-shot only.** `efx_cont` resumes a continuation once. Multi-shot resumption
  is out of scope.
- **No effect rows.** A function taking `*const Scope` may perform any effect.
  A missing handler panics at dispatch rather than failing to compile at the
  call site. `efx.Contract` checks completeness at the wiring site only.
- **`std.Io` is young.** Validated against Zig 0.17.0. The
  `concurrent`/`Queue`/`Future` surface may still change.
