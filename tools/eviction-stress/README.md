# P4 — does instrumentation elision change what TSan misses under shadow-cell pressure?

Rebuttal experiment P4 (`~/tsan-instr-paper/plan/rebuttal-experiments.md`). The reviewers' concern:
every 8-byte granule has only 4 shadow cells; an access that the optimised build no longer
instruments does not compete for those cells, so elision could change which earlier accesses
are still remembered when a racing access arrives — i.e. change detection of races that are
*not* touched by the elision itself.

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

Eviction victim in the TSan v3 runtime: `MemoryAccess` picks the free cell if any, otherwise
`(trace_pos / 2) % 16 / 4` of the **evicting** thread — i.e. a period-4 function of how many
events that thread has traced so far (accesses, function entry/exit, intercepted calls). The
burst length therefore rotates the victim among {A, 1, 2, 3} with period 4 when the burst is
instrumented, and does not affect it at all when the burst is elided.

Two implementation details that cost time to get right (kept as comments in the source):

* the fillers must store **one at a time**: `CheckRaces` is not atomic across threads, so two
  concurrent stores can both pick the same free cell, leaving one cell free — then F4's store does
  not evict anything and the outcome looks like a spurious 20–40 % "leak" in every build;
* stock TSan does not instrument accesses to an uncaptured `alloca`, so the private buffer must be
  `malloc`ed for the stock build to trace the burst at all.

`-DSHADOW_PROBE` adds a `no_sanitize("thread")` function that reads the 4 raw shadow cells of the
granule after every phase (x86_64 mapping `(x & ~(0x700000000000|7)) * 2 + 0x100000000000`) and
prints `acc/sid/epoch` per cell, which shows the eviction directly (e.g. `n=40`: F4 sid 5 evicted
cell 3 → race reported; `n=41`: F4 evicted cell 0 = A's record → B finds no conflict).
Probe binaries: `bin/probe/evict_stress.{tsan,tsan-sound}`.

## Scripts

    ./build.sh [bin_dir]          # stock, -st, -ea, -sound (EA+LO+ST+SWMR), AllOpt via tools/tsan_compiler.sh
    ./run.sh   [bin_dir] [runs]   # sweep, random and fixed-prefix tables -> results/<date>-<compiler>/report.md

`build.sh` writes `bin/build_info.txt` (compiler, flags, number of `__tsan_*` calls left in
`burst_local`, `burst_shared` and stores to `g`). `run.sh` runs (1) the deterministic sweep
N, M = 0..15 × 3 runs, (2) 1000 runs per build and mode with N, M drawn from
`random.Random(20260902)` in [0, 1023] — the same sequence for every build — with Wilson 95 %
intervals, (3) a fixed escaping prefix M = 0..3 with random N. Per-run outcomes are kept next to
the report. To A/B against the paper compiler: `LLVM_TSAN_ROOT=/extra/alexey/llvm-project-paper/llvm/build ./build.sh bin-paper && ./run.sh bin-paper 1000`.

## Results (`results/2026-09-02-89e5d0078d2f/report.md`, tsan-dev 89e5d0078d2f)

Sweep, one character per burst length 0..15 (1 = reported in all 3 runs, 0 = in none; there were
no mixed outcomes — the experiment is fully deterministic):

| build | private burst N | escaping burst M |
|---|---|---|
| tsan, tsan-st | `1110111011101110` | `1011101110111011` |
| tsan-ea | `1111111111111111` | `1011101110111011` |
| tsan-sound, AllOpt | `1111111111111111` | `1101110111011101` |

Random N, M in [0, 1023], 1000 runs per cell (detection rate of the planted race):

| build | private only | escaping only | both |
|---|---|---|---|
| tsan, tsan-st | 75.4 % | 74.2 % | 74.7 % |
| tsan-ea | 100 % | 74.2 % | 73.6 % |
| tsan-sound, AllOpt | 100 % | 73.9 % | 76.5 % |

Fixed escaping prefix M, random private N, 200 runs per cell:

| build | M=0 | M=1 | M=2 | M=3 |
|---|---|---|---|---|
| tsan, tsan-st | 157 | 149 | 152 | 143 |
| tsan-ea | 200 | 200 | **0** | 200 |
| tsan-sound, AllOpt | 200 | 200 | 200 | **0** |

Paper compiler (e90a3fc41004, `bin-paper/`, `results/2026-09-02-e90a3fc41004/report.md`): every cell of
all three tables is identical to the tsan-dev numbers above (same binaries' instrumentation of the
burst functions; the fixed-seed sequence makes the comparison exact).

## Reading

* Stock TSan detects the planted race in ~3/4 of the runs whenever the burst is instrumented:
  the victim cell is a hash of an arbitrary event count, and A's record is one of four candidates.
  This is the baseline "miss under pressure" and has nothing to do with our passes.
* When the burst is elided (private buffer under EA) the outcome stops depending on N and becomes a
  per-binary constant — 100 % in the tables above, but that constant is just where the fixed
  trace position happens to land: with two (EA) or three (sound/AllOpt) escaping stores in front of
  it the same builds report the race in **0 %** of the runs. The difference between the EA and
  sound flip points is one elided `__tsan_read8` (the load of the `shared_buf` pointer, elided by
  SWMR/STC as a never-written global).
* Elision neither systematically helps nor hurts: the escaping-burst and mixed columns, where the
  evicting thread still traces a length-dependent number of events, are statistically identical
  across all five builds (Wilson intervals overlap; 1000 runs each).
* So the honest answer to the reviewers is: shadow eviction is a pre-existing, effectively random
  loss mechanism of the TSan runtime (25 % on a single 4-way contended granule); our passes change
  the trace-position arithmetic and therefore *which* concrete interleaving is lost, not how many
  are lost in expectation. A race whose own accesses are instrumented is not made systematically
  less detectable by eliding unrelated, provably thread-local accesses.

Caveat: this is a single granule with exactly 4 competing accesses, the worst case for the 4-cell
shadow. Real programs mostly have fewer distinct threads touching a granule between the two racing
accesses; then no eviction happens and the elision is irrelevant to detection.

_Provenance note (commit ids of the tsan-dev binary: the compiler was built 2026-09-02 07:07 from the tree that then carried 89e5d0078d2f / HEAD 0de7a7350375; tsan-dev rewrote its history on 2026-09-02 18:15, so these ids now resolve only as loose objects; the same content is 775a6d721e02 on the rewritten branch, declared final as e5080b0ab463)._

## DE-specific variant (reviewer E's scenario): `de_stress.c`, `de_build.sh`, `de_run.sh` — 2026-09-03, final compiler f80e80b1dbe6

Thread A stores `x` twice in one function with no synchronization between the stores (only a volatile spin
through a pointer, which keeps the first store alive for DSE while DE sees no sync); the second store is dominated
by the first and DE removes its instrumentation (verified: `a_body` has 2 `__tsan_write1` in stock/sound, 1 in
DE/AllOpt+peel, the survivor at line 50 = the first store). Between A's stores, three fillers occupy the granule's
other cells and an evicting thread does an escaping burst of M stores (instrumented in every build) and then
stores, evicting a cell chosen by its trace position. Thread B then writes `x` without synchronization. A shadow
probe after the evicting store records whether A's first record survived. Ordering by `no_sanitize` flags
(invisible to TSan, no happens-before). Results in `results/de-2026-09-03-f80e80b1dbe6/report.md`:

Sweep M = 0..15: A's record is evicted exactly for M ≡ 2 (mod 4) in every build; stock and sound report the race
for every M; DE and AllOpt+peel report it for every M except those.

Random M in [0, 1023], 1000 runs per build, same sequence for all builds:

| config | detected (all runs) | A's record evicted between the stores | detected given evicted | detected given not evicted |
|---|---|---|---|---|
| stock | 100.0 % [99.6, 100.0] | 252/1000 | 252/252 = 100 % | 748/748 = 100 % |
| tsan-sound | 100.0 % [99.6, 100.0] | 252/1000 | 252/252 = 100 % | 748/748 = 100 % |
| tsan-dom (DE only) | 74.8 % [72.0, 77.4] | 252/1000 | **0/252 = 0 %** | 748/748 = 100 % |
| AllOpt+peel | 74.8 % [72.0, 77.4] | 252/1000 | **0/252 = 0 %** | 748/748 = 100 % |

Reading: exactly as reviewer E describes — when the dominating store's record has been evicted before the
dominated store executes, stock TSan re-inserts it with the second store and reports the race, while DE, having
removed the second store's instrumentation, cannot, and the race is missed in 100 % of those interleavings. When
the record was not evicted, DE changes nothing (100 % in both): the second identical store by the same thread in the
same epoch hits TSan's same-access fast path and writes no shadow anyway. The unconditional rate is therefore
1 − P(eviction lands between the two stores), here 74.8 % because the evicting thread's victim is uniform over the
four cells. The sound bundle (EA+LO+STC+SWMR) is unaffected. This is the bounded-shadow cost of DE, measured; how
often such interleavings occur in real workloads is what the per-granule counters (`tools/eviction-counters`) and
the P2 rows measure (on SQLite/memcached, no DE-attributable loss at the location level).

## Symmetric variant (both of DE's bounded-shadow effects): `de_stress2.c`, `de_build2.sh`, `de_run2.sh` — 2026-09-03, f80e80b1dbe6

Two planted races on one granule: A stores x = g[0] twice in one function with no synchronization between (second
store dominated → elided by DE); C stores y = g[1] (its own cell); F2, F3 fill the other cells; F4 does an escaping
burst of M stores and stores (victim = f(its trace position)); then A's second store runs (in stock/sound it
re-inserts A's record — and, the granule being full, evicts a cell chosen by A's trace position, set by an in-function
burst of MA traced stores); then B does a burst of MB, stores y, then x. Probes after F4's store, after A's second
store and after B's y store. Because TSan clears the granule's shadow after reporting a race (a runtime property,
identical in every build), B checks y first so that the C–B race — the one DE can keep where stock cannot — is
observed independently of A–B; A–B is then only reportable when no C–B report preceded it. Results in
`results/de2-2026-09-03-f80e80b1dbe6/report.md` (sweeps over M and over MA at M = 2 are fully deterministic with period 4).

Random (M, MA, MB) in [0, 1023]³, 1000 runs per build, same sequence for all builds:

| config | races/run | A–B reported | C–B reported | (i) A's record evicted by F4 | A–B given (i) | C–B given (i) | (ii) C's record evicted by A's 2nd store | C–B given (ii) | C evicted by F4 → C–B |
|---|---|---|---|---|---|---|---|---|---|
| stock | 0.91 | 22.8 % [20.3, 25.5] | 68.2 % [65.2, 71.0] | 236/1000 | 54/236 = 22.9 % | 165/236 = 69.9 % | 71/1000 | **0/71** | 247 → 0/247 |
| tsan-sound | 0.92 | 22.6 % [20.1, 25.3] | 69.6 % [66.7, 72.4] | 236/1000 | 41/236 = 17.4 % | 179/236 = 75.8 % | 57/1000 | **0/57** | 247 → 0/247 |
| DE only | 0.93 | 17.4 % [15.2, 19.9] | 75.3 % [72.5, 77.9] | 236/1000 | **0/236** | **236/236 = 100 %** | 0 (issues no store) | — | 247 → 0/247 |
| AllOpt+peel | 0.94 | 18.5 % [16.2, 21.0] | 75.3 % [72.5, 77.9] | 236/1000 | **0/236** | **236/236 = 100 %** | 0 | — | 247 → 0/247 |

Reading: the two effects are complementary, as predicted. (i) When F4 evicted A's record, stock re-inserts it with
the second store, DE cannot: DE reports A–B in 0/236 of those runs. (ii) In stock the re-inserting store, with the
granule full, evicts a cell of its own — C's in 71 runs (MA ≡ 2 mod 4 in the sweep) — and then C–B is lost 71/71;
DE issues no store, so C's record survives and C–B is reported in 236/236 of the (i) runs. Totals are comparable
(0.91–0.94 races per run); DE trades A–B (−5.4 points) for C–B (+7.1 points). Both builds lose C–B whenever F4
itself evicted C (247 runs), and both are bounded by the runtime's post-report clearing, which is why A–B is low
everywhere. The sound bundle behaves as stock up to its own trace positions. Note for the model: an eliminated
dominated access is neither a pure loss nor a pure gain under bounded shadow — it stops re-inserting the covering
record (loss when that record was evicted) and stops evicting others (gain for every other record on the granule).
