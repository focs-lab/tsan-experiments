# Shadow-cell pressure and instrumentation elision

Documents `evict_stress.c` and `de_stress2.c` and the scripts that build and run them (`build.sh`,
`run.sh`, `de_run2.sh`). The question: when instrumentation is elided, does TSan miss races it would
otherwise find under shadow-cell pressure?

## Program (`evict_stress.c`)

One 8-byte granule `g[0..7]` (one byte per thread), six threads, one planted write-write race
(`g[0]=1` in thread A, `g[0]=2` in thread B). All threads are serialised with
`__tsan_testonly_barrier_*`, which is invisible to the race detector (traces nothing, creates no
happens-before). Phase order:

| phase | thread | action |
|---|---|---|
| 0 | A | `g[0] = 1` (the record B must later find) |
| 1..3 | fillers 1..3 | `g[k] = 1` — the granule's 4 cells are now A, 1, 2, 3 |
| 4 | F4 | *burst*, then `g[4] = 1` — the store evicts one of the four cells |
| 5 | B | `g[0] = 2` — the race is reported iff A's cell survived phase 4 |

The burst is the variable: `N` stores to a private heap buffer (never escapes; only the address
is passed to an `asm` barrier), and/or `M` stores to a global buffer that is then passed to
`write(-1, …)` (escapes). Stock TSan instruments both loops; the escape-analysis builds elide the
private one and keep the shared one.


## Scripts

    ./build.sh [bin_dir]          # stock, -st, -ea, -sound (EA+LO+ST+SWMR), AllOpt via tools/tsan_compiler.sh
    ./run.sh   [bin_dir] [runs]   # sweep, random and fixed-prefix tables -> results/<date>-<compiler>/report.md

`build.sh` writes `bin/build_info.txt` (compiler, flags, number of `__tsan_*` calls left in `burst_local`,
`burst_shared` and stores to `g`). `run.sh` runs (1) the deterministic sweep N, M = 0..15 x 3 runs, (2) 1000
runs per build and mode with N, M drawn from `random.Random(20260902)` in [0, 1023] -- the same sequence for
every build -- with Wilson 95 % intervals, (3) a fixed escaping prefix M = 0..3 with random N. Per-run
outcomes are kept next to the report. Set `LLVM_TSAN_ROOT` to build against another compiler.

## Reading the report

* Stock TSan detects the planted race in about three quarters of the runs whenever the burst is
  instrumented: the victim cell is a hash of an arbitrary event count and the record is one of four
  candidates. That is the baseline miss rate under pressure and is a property of the runtime, not of any
  analysis.
* When the burst is elided the outcome stops depending on N and becomes a per-binary constant. The constant
  is where the fixed trace position happens to land: with two or three escaping stores in front of it the
  same builds report the race in 0 % of runs. Read the constant, not its value.

## Variants

`de_stress2.c` / `de_run2.sh`: two planted races on one granule, exercising both of dominance analysis's
bounded-shadow effects at once.
