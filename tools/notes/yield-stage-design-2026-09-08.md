# The yield stage: measuring the seven yield changes without the stage-b2 changes underneath

**Date** 2026-09-08 · **lane** tsan-exp · **compiler** `/extra/alexey/builds/tsan-yield-d98873cda906`
(`yield/all-b2` = stage-b2 `c38c1e7e94ec` + the seven yield changes; counters OFF).

## Why the obvious comparison is the wrong one

The Stage B tables are measured on `tsan-perf-d3bf9f8c39fe`. The yield copy does not sit on that commit: it
sits on `c38c1e7e94ec`, which is d3bf plus the parser join-sharing and the Chromium pointee-view changes.
A yield-copy row read against a d3bf row therefore mixes two independent sets of changes, and nothing in the
number says which one moved it. There is no measured leg on `c38c1e7e94ec` to subtract, and measuring one
would cost a second full sweep.

## The A/B that avoids it

Every yield change is behind a hidden `-mllvm` switch that defaults to **on**, so the off half is reachable
from the same binary tree. The stage adds one configuration token, `yoff`, that sets all six switches false:

    -tsan-dynstc-runs-across-thread-free-calls=false  -tsan-de-atomics-by-ordering=false
    -tsan-de-cover-containment=false                  -tsan-swmr-readonly-call-args=false
    -tsan-ea-later-escape-uses-summaries=false        -tsan-intercepted-call-table=false

A row named `<config>-yoff` is then the partner of `<config>`: **one compiler, one set of application sources,
one build recipe, differing only in the yield changes.** Whatever the stage-b2 changes do to the number, they
do it to both halves, so the ratio between the pair is attributable to the yield changes alone. The token
lives in the four `config_definitions.sh` files and in `nosql/redis/redis.sh`'s own token parser; the driver's
`P5_YIELD` set is

    orig  tsan  tsan-yoff  tsan-stmt  tsan-stmt-yoff  tsan-sound  tsan-sound-yoff
    tsan-dom_peeling-ea-lo-st-swmr  tsan-dom_peeling-ea-lo-st-swmr-yoff

`orig` is uninstrumented, so it has no partner; it is carried only as the slowdown denominator.

## Which pair answers which change

| change | switch | the pair that shows it |
|---|---|---|
| C1 DynSTC across thread-free calls | `-tsan-dynstc-runs-across-thread-free-calls` | `tsan-stmt` vs `tsan-stmt-yoff` |
| C3 dominance cover by byte-range containment | `-tsan-de-cover-containment` | AllOpt+peel pair (SQLite) |
| C5 later-escape sites through summaries | `-tsan-ea-later-escape-uses-summaries` | `tsan-sound` pair, AllOpt+peel pair |
| C6 interceptor toggle table | `-tsan-intercepted-call-table` | every instrumented pair, `tsan` included |
| C2, C4 | `-tsan-de-atomics-by-ordering`, `-tsan-swmr-readonly-call-args` | ≈0 static; folded into the same pairs |

C6 is a runtime change, so it is the only one that can move the plain `tsan` pair; a `tsan` vs `tsan-yoff`
difference is C6 and nothing else.

## Scope and cost

Four applications (memcached, Redis, SQLite, FFmpeg), N = 5, nine rows each. MySQL is excluded: its rows cost
about eleven hours of measurement and its sysbench signal has straddled 1.0 in every configuration measured so
far. Builds on this compiler are cheap — FFmpeg 90-180 s per configuration, the rest seconds — because the
escape-analysis compile-time cliff is gone on the stage-b2 base.

Driver: `tools/perf/stageB_yield.sh d98873cda906`. It builds all four applications, writes
`static-diff-vs-stage-b.md`, then measures memcached, Redis, FFmpeg and SQLite in that order, so the fast
applications answer before SQLite's long leg. Every measurement runs alone under the machine job lock.

**Verified before arming** (2026-09-08): the yield clang accepts all six switches with and without the sound
bundle (`rc = 0`, three trial compiles), and the token composition produces exactly the intended flag list for
all four `-yoff` names.

## Static result, before any timing (2026-09-09 06:07)

All 36 builds succeeded, nine configurations on each of four applications, no failures. Paired inside the one
compiler, memory-access sites with the yield changes on against the same configuration with all six switches
off:

| configuration | FFmpeg | memcached | Redis | SQLite |
|---|---|---|---|---|
| `tsan` | +0 | +0 | +0 | +0 |
| `tsan-sound` | −100 (−0.02 %) | −3 (−0.05 %) | −3 (−0.01 %) | −19 (−0.03 %) |
| AllOpt+peel | −1234 (−0.23 %) | −3 (−0.04 %) | −49 (−0.11 %) | −59 (−0.10 %) |
| DynSTC | +47 (+0.01 %) | +0 | −4 (−0.01 %) | +4 (+0.01 %) |

Two things follow, and both are worth fixing in writing before the timings arrive.

**The plain `tsan` pair is statically identical on all four applications.** That is the design working: C6, the
interceptor toggle table, is a runtime change, so whatever the `tsan` pair shows in time is C6 alone and cannot
be anything else.

**Nothing here can buy a measurable speedup through instrumentation removal.** The largest static effect in the
whole matrix is 0.23 %, and the campaign's own resolution is 1.9 pp at best (FFmpeg) and 4 pp on Redis. So if a
pair moves, the cause is the runtime — the interceptor table, or C1 changing where DynSTC's guards sit — and
not fewer instrumented accesses. A prediction recorded before the measurement, so it cannot be fitted to it
afterwards.

The `-yoff` builds also match the Stage B binaries almost exactly (FFmpeg AllOpt+peel 542 683 against
542 684 on `d3bf9f8c39fe`, a difference of one site), which confirms the stage-b2 base contributes nothing
statically here and that the pair really does isolate the yield changes.

## Result (2026-09-09 14:31): the seven yield changes are worth nothing measurable

Four applications, nine rows each, N = 5, all 36 rows complete, 2 runs retired and re-run. Sixteen pairs:

| application | plain `tsan` (C6 alone) | sound | AllOpt+peel | DynSTC |
|---|---|---|---|---|
| FFmpeg | 1.009 [0.998, 1.019] | 1.000 [0.992, 1.008] | 0.997 [0.989, 1.010] | 1.008 [0.996, 1.012] |
| Redis | 1.000 [0.985, 1.025] | 0.998 [0.977, 1.020] | 0.991 [0.951, 1.008] | 1.005 [0.984, 1.024] |
| SQLite (resolvable subtests) | 0.996 [0.968, 1.022] | 0.987 [0.963, 1.026] | 1.016 [0.993, 1.030] | 1.008 [0.976, 1.036] |
| memcached | 0.981 [0.967, 1.017] | 1.000 [0.929, 1.042] | 0.996 [0.929, 1.068] | 0.995 [0.945, 1.054] |

**Not one of the sixteen intervals excludes 1.0.** The tightest bound in the matrix is FFmpeg's sound pair at
1.000 [0.992, 1.008], so on the application that resolves best the seven changes together are worth less than
one percent in either direction. The plain `tsan` pairs, where the two binaries are byte-identical in
instrumentation and only the interceptor toggle table differs, are 1.009, 1.000, 0.996 and 0.981: C6 on its own
does nothing measurable either.

This is what the static counts predicted before any timing was taken. The largest static difference in the
matrix was 0.23 % and the campaign's best resolution is about 1 pp, so there was nothing for a timing effect to
come from. The prediction was recorded in the section above, before the measurements, and it held.

## A replication that was not planned

DynSTC on FFmpeg reads **1.114 [1.103, 1.124]** with the yield changes on and **1.105 [1.099, 1.119]** with them
off, against **1.113 [1.097, 1.124]** on `tsan-perf-d3bf9f8c39fe` (`tools/notes/stageb-results-2026-09-09.md`).
The campaign's one substantial result therefore reproduces at three independent settings across two separately
built compilers with different bases, with near-identical magnitude and no interval touching 1.0. Native against
stock TSan also agrees across the two compilers on this workload, 2.804 against 2.813.

That matters more than the null above: a single application showing an 11 % gain where nothing else moves is
exactly the shape a measurement artefact takes, and this is the strongest evidence available here that it is not
one.
