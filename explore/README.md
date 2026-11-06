# Exploration

Prototypes for directions beyond the released library. Nothing here is part of
efx, and all of it is aarch64 macOS only.

```sh
cd explore
zig build test                        # every optimize mode
zig build -Doptimize=ReleaseFast      # always benchmark with this
zig-out/bin/switch                    # what a stack switch costs
zig-out/bin/dod_attr                  # the same, through the whole pool
zig-out/bin/dod_perf                  # the lookup workload
```

## `continuations/`: full effects without giving up data layout

`co.zig` is one-shot continuations on fibers, plus stack-copy multi-shot.
`dod.zig` is the data-oriented version: continuations are generation-checked
handles into a fixed pool, stacks are computed from the handle, `perform`
appends one row to a request queue, and a handler is a batch transform.

### Switch cost

Measured on an Apple M5 Pro. Times are ns per park and resume.

| Bare switch | Old (`bl`/`ret`) | New (inline, `br`) |
|---|---:|---:|
| One fiber, same frame | 19.2 | 3.9 |
| One fiber, 3 frames deep | 21.4 | 4.2 |
| 8 fibers at 8 sites, cyclic | 35.7 | 22.7 |
| 8 fibers at 8 sites, random | 33.2 | 25.0 |
| 256 fibers, one site, no queue | 23.9 | 8.9 |
| 4096 fibers, one site, no queue | 33.9 | 12.4 |

| Whole pool, through efx | Old | New |
|---|---:|---:|
| 1 task | 50.6 | 25.6 |
| 16 tasks | 55.0 | 32.6 |
| 256 tasks | 55.4 | 33.6 |
| 4096 tasks (noisy) | 102-126 | 52-93 |

Lookup workload: 64, 59 and about 90 ns per lookup at 16, 256 and 4096 tasks
became 41, 39 and 70-85 ns. Plain calls take about 105 ns and a hand-written
SoA loop 4-7 ns.

What the cost was:

- **The `ret` in the switch.** A `ret` is predicted from the return-address
  stack, and a switch returns to somewhere other than its own caller, so it
  mispredicts every time. That was about 16 ns per pair, the largest single
  cost. `swap.InlineBr` leaves with `br` and is inlined at each site, so it
  neither pushes nor pops that stack, and the branch predictor learns the
  target.
- **Not the return chain.** I expected each return above a switch to mispredict
  as well. It doesn't: `call+ret` costs about 0.6 ns per frame. `call+br`, which
  pushes without popping, shows what that failure looks like, at about 5 ns per
  frame.
- **Register saves, a little.** Saving only sp, pc and fp (`InlineMin`) takes
  3.9 ns to 1.2 ns when the switch is inlined into the loop. Behind a real call
  the prologue saves the registers instead and the gain falls to about 1 ns.
  Zig's `aarch64_preserve_none` could recover that. It isn't worth trying until
  the queue path below is cheaper.

Traps:

- **Clobber `.lr`, not `.x30`.** LLVM silently ignores `.x30`, keeps a live value
  in the register across the switch, and corrupts the scheduler in optimized
  builds only. `zig build test` runs every mode because of this.
- **Mispredicts come back when parking is unpredictable.** At 8 random sites
  `InlineBr` still mispredicts on resume, so the gain shrinks from 16 ns to 8.
  It stayed ahead of `bl`/`ret` in every switch benchmark. In the noisy 4096-task
  pool runs, one of six comparisons went the other way.

### Open questions

- **The queue path.** A switch is 4-9 ns, but the pool takes 25-34 ns, so about
  20 ns is in the queue, batch and ready-list bookkeeping. That is now the
  largest cost and it is unexplained. A few column loads and stores should cost
  far less. One suspect: the columns are all the same size, so element `i` of
  each one lands on the same cache set.
- **4096 tasks.** These runs vary by up to 2x, and 16K stacks cost about 5 ns
  more than 64K ones, which is not yet explained either.
- **Portability.** Only aarch64 has a switch, and `InlineBr` has not been tried
  on x86_64, where `ret` prediction and shadow stacks both differ.
- **`co.zig`** still uses a `bl`/`ret` switch. Multi-shot has not been moved over.

## `registry/`: compile-time slot indices

Effects are declared once as `pub const efx_effects = .{...}` in the root file,
so the slot is a comptime index. Unused slots hold a stub, so there is no
"unbound" check. This is the only variant that matched a hand-written vtable on
every small-handler case, and `exec` and `bind` fold away entirely when the scope
is known at compile time. `View` is a phantom-typed narrowing of a scope to a set
of effects, checked at compile time.

The released library stays with runtime slots: the gain is about 0.2 ns, and it
costs a declaration in the application's root file. The registry is worth
revisiting if a full effects runtime calls effects far more often. Columns
(`d_cols.zig`) showed no clear gain over slots.

Untested: the `zig test` fallback, handlers using `sc` inside a view, and `View.of`
does not check that the effects are bound. `view_bad_use.zig`,
`view_bad_narrow.zig` and `reg_missing.zig` must fail to compile.
