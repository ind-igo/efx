# Exploration

Prototypes for directions beyond the released library. Nothing here is part of
efx, and all of it is aarch64 macOS only.

```sh
cd explore
zig build test                        # every optimize mode
zig build -Doptimize=ReleaseFast      # always benchmark with this
zig-out/bin/switch                    # what a stack switch costs
zig-out/bin/dod_attr                  # the same, through the whole pool
zig-out/bin/queue                     # pool cost by capacity, dod against tiny
zig-out/bin/dod_perf                  # the lookup workload
```

## The constraint

efx stays small: 268 lines before the tests, 184 of them code. Anything here has
to earn its lines, and nothing here should change `src/`.

| Direction | Code lines | Result | Verdict |
|---|---:|---|---|
| `tiny.zig` + `swap.zig`: parked tasks and batching | +216, separate | Lookups 5x faster than plain calls | Best candidate for an optional add-on |
| `dod.zig` instead of `tiny.zig` | +48 more | About 1 ns slower, adds keep-and-resume-later | Only if that capability is needed |
| x86_64 switch | about 40 of the 216 | Passes tests under Rosetta | Keep with the add-on |
| Registry, minimal | -12 | About 0.2 ns, breaks `zig test` | Drop |
| `preserve_none` | Changes `src/` | 4.1 ns to 2.4 ns | Drop |
| Multi-shot (`co.zig`) | 115 | Not pursued | Drop |

## `continuations/`: full effects without giving up data layout

`co.zig` is one-shot continuations on fibers, plus stack-copy multi-shot. It still
uses the old switch.

`dod.zig` is the data-oriented version: continuations are generation-checked
handles into a fixed pool, stacks are computed from the handle, `perform` appends
one row to a request queue, and a handler is a batch transform.

`tiny.zig` is the same idea with one queue. A row holds a request until the batch
runs and the reply after it, so there is no ready list and no reply column.

| | `tiny` | `dod` |
|---|---|---|
| Park, batch, resume | Yes | Yes |
| Cancel | Every parked task | One task, by handle |
| Keep a continuation past a batch | No | Yes |
| Stale handle check | Not needed, handles never escape | Yes |
| Tasks spawning tasks | No | Yes |

### Cost

Measured on an Apple M5 Pro in `ReleaseFast`. Times are ns per park and resume.

| Bare switch | `bl`/`ret` | Inline `br` |
|---|---:|---:|
| One fiber, same frame | 18.3 | 3.9 |
| One fiber, 3 frames deep | 20.4 | 4.1 |
| 8 fibers at 8 sites, cyclic | 33.8 | 21.7 |
| 8 fibers at 8 sites, random | 32.1 | 23.7 |
| 256 fibers, no queue | 22.4 | 8.7 |
| 4096 fibers, no queue | 33.1 | 12.1 |

| Whole `dod` pool, through efx | `bl`/`ret` | Inline `br` |
|---|---:|---:|
| 1 task | 27.5 | 8.8 |
| 16 tasks | 24.3 | 11.1 |
| 256 tasks | 24.8 | 10.7 |
| 4096 tasks | 28.4 | 13.5 |

| ns per lookup | 16 tasks | 256 tasks | 4096 tasks |
|---|---:|---:|---:|
| Plain calls | 109 | 109 | 98 |
| Pool, first version | 64 | 59 | about 90 |
| Pool, now | 21 | 15 | 19 |
| Hand-written SoA | 7.4 | 3.8 | 4.4 |

Where the original 50 ns went:

- **A copied bitset, about 25 ns.** `abort_bits.isSet(i)` takes the bitset by value,
  so every park copied it: 2 KiB at capacity 16384. The cost grew with capacity
  rather than with tasks, and it caused the noise at 4096 tasks too. A
  `[capacity]bool` column fixes it, and `tiny` has neither.
- **The `ret` in the switch, about 16 ns.** A `ret` is predicted from the
  return-address stack, and a switch returns somewhere other than its own caller,
  so it mispredicts every time. `swap.InlineBr` is inlined at each site and leaves
  with `br`, so it neither pushes nor pops that stack, and the branch predictor
  learns the target.
- **Not the return chain.** `bl`/`ret` costs about 0.6 ns per frame. `call+br` in
  `switch.zig`, which pushes without popping, shows what a broken chain looks like
  at about 5 ns per frame.
- **Register saves, a little.** Saving only sp, pc and fp takes 3.9 ns to 1.1 ns
  when the switch is inlined into the loop. Behind a real call the prologue saves
  them instead and the gain is about 1 ns. `aarch64_preserve_none` frames reach
  2.4 ns at depth 3, but efx's trampolines would have to use that convention too.

Traps:

- **Clobber `.lr`, not `.x30`.** LLVM silently ignores `.x30`, keeps a live value in
  the register across the switch, and corrupts the scheduler in optimized builds
  only. `zig build test` runs every mode because of this.
- **`preferred_optimize_mode` hides `-Doptimize`.** Plain `zig build` then gives you
  Debug. Pass `-Doptimize=ReleaseFast` to anything you measure.
- **Unpredictable parking costs a mispredict.** At 8 random sites the switch's gain
  shrinks from 16 ns to 8. A real program with many kinds of tasks is nearer that
  row than the first one.
- **`std` bitsets are by value.** `isSet` on an `ArrayBitSet` can compile to a full
  copy. Here it did, in `ReleaseFast`: `memcpy` of 2 KiB right after the switch.

### Open questions

- **efx inside the pool.** Dispatch adds 1 ns with one task but about 5 ns from 16
  tasks up, more than a call should. Not explained yet.
- **Lookups are 3-4x a hand-written loop.** Most of that is one park per lookup.
  Whether any of it can go is unmeasured.
- **Typed requests.** `tiny` carries a `u64` per row. A real add-on needs a typed
  request and reply, ideally without more lines.
- **x86_64 speed.** The switch passes every test in all four modes under Rosetta,
  which shows it is correct, not how fast it is. Linux and real x86 hardware are
  untested. The `leaq -128(%rsp)` skips the red zone; aarch64 doesn't need that
  because LLVM doesn't use one there by default.

## `registry/`: compile-time slot indices

Effects are declared once as `pub const efx_effects = .{...}` in the root file, so
the slot is a comptime index and the atomics go away. Unused slots hold a stub, so
there is no "unbound" check. `View` narrows a scope to a set of effects at compile
time.

This was the only variant that matched a hand-written vtable on every small-handler
case, and `exec` folds away when the scope is known at compile time. A minimal patch
to the current core is 12 lines shorter.

It doesn't fit efx, because `zig test` won't compile:

```
efx.zig:7:37: error: root source file struct 'test_runner' has no member named 'efx_effects'
```

Under `zig test` the root module is the test runner, so nobody could test their
handlers, and that is efx's main use. A fallback means keeping the runtime slots as
well, which is more code rather than less. The gain is about 0.2 ns.

`d_cols.zig` showed no clear gain over slots. Also untested: handlers using `sc`
inside a view, and `View.of` does not check that the effects are bound.
`view_bad_use.zig`, `view_bad_narrow.zig` and `reg_missing.zig` must fail to compile.
