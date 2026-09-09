# DynSTC is the one lever that moves anything, and it moves in both directions

**Date** 2026-09-08 · **lane** tsan-exp · **compiler** `/extra/alexey/builds/tsan-perf-d3bf9f8c39fe`
· **tree** `tools/perf/results/stageB-d3bf9f8c39fe` · N = 5, pinned to `4-27,60-83`, powersave-variable clock.

## The finding

Across five applications and twelve configurations, almost every speedup interval straddles 1.0. The exception
is `tsan-stmt` (DynSTC, `-mllvm -tsan-use-active-thread-count`), and it does not have one sign:

| application | SU vs stock TSan | 95 % interval | over resolvable subtests | static sites vs stock |
|---|---|---|---|---|
| FFmpeg | **1.113** | [1.097, 1.124] | (all subtests resolvable) | 514 493 vs 514 609 (−116) |
| memcached | 1.006 | [0.955, 1.068] | (single test) | 6 810 vs 6 748 (+62) |
| SQLite | 0.988 | [0.942, 1.130] | **0.983 [0.978, 0.995]** | 57 957 vs 57 996 (−39) |
| MySQL | 0.990 | [0.912, 1.061] | not resolvable | 602 809 vs 602 434 (+375) |
| Redis | **0.969** | [0.950, 0.990] | 0.968 [0.950, 0.987] | 37 882 vs 37 941 (−59) |

Three applications now have intervals that exclude 1.0, and they do not agree in sign. SQLite joined them once
the geometric mean was also computed over the subtests the data can resolve: its `stress1` (19.9 %), `dynamic_triggers` (16.1 %) and
`stress2` (5.5 %) carry the workload's noise while the other four sit at 0-4 %, and a mean over all seven
inherits it. The subset comes from each subtest's pooled noise across every configuration, not from the baseline's five
runs, so it is a property of the workload rather than of a configuration, and both columns are reported, so the exclusion cannot favour a configuration. Note the two columns are
not interchangeable: the paper's SQLite figure is a mean over all seven subtests, so only the all-subtest
column is comparable with it.

MySQL settles nothing, and the leg shows why quoting it early would have been wrong: the same row read 0.965 at
one repetition, 1.033 at three and 0.990 at five. Its five sysbench scripts carry 4.1 to 8.6 % pooled
run-to-run noise, so four of them fail the resolvability filter and the restricted mean is suppressed rather
than reported — with one subtest left it would be a different quantity, not a cleaner one.

The static counts say the difference between the applications is not in what was removed: DynSTC changes the
site count by well under 1 % everywhere. The effect is entirely at run time, in what the thread-count guard
costs versus what it saves.

## Why the sign differs

DynSTC replaces a memory-access callback with a guarded one: load the active thread count, skip the callback
while it is 1. An application that is genuinely single-threaded for part of its run gets the skip; one that is
never single-threaded pays the load and gets nothing.

- **Redis is never single-threaded.** `main` calls `bioInit()` (and `initThreadedIO()`) during startup, before
  the first client connects, and `bioInit` `pthread_create`s its background I/O threads
  (`redis-summaries-work/src/bio.c:127`, called from `server.c:2691`). The count is above 1 from before the
  benchmark starts until the server exits, so every guard is a pure add. A 3 % loss is what that costs.
- **SQLite is multi-threaded wherever the time is spent.** `threadtest3` launches its workers per subtest and
  joins them at the end of it (`sql/sqlite/threadtest3.c`, `join_all_threads` at 1062, 1119, 1181, 1235), so the
  windows where the count is back to one are the gaps between subtests, not the timed bodies. The guard is
  therefore paid throughout the work and saves almost nothing. The measured loss, 1.9 %, is smaller than
  Redis's 3.1 %, which fits: SQLite does more work per instrumented access, so the added load is a smaller
  share of it. This is the workload's structure, not a counter measurement.
- **FFmpeg is single-threaded in phases.** The benchmark runs `ffmpeg -threads 4` per codec; demux, parse and
  container setup run on one thread, and the codec worker pool exists only around the encode. An 11 % gain is
  the largest effect measured anywhere in this campaign, and it is the only configuration that beat stock TSan
  by more than the noise on any application.

**Not verified:** the FFmpeg half is inferred from the workload's structure, not from a counter. The runtime
elision counters live in `tsan-perf-d3bf9f8c39fe-evictstats`, which has no `opt` and was built for P3; counting
guard hits per phase would need a counters build of the yield base. Worth doing if the paper wants to state the
mechanism rather than the measurement.

## What follows for the tables

DynSTC cannot be reported as an optimisation that helps: on this compiler it is a workload-shape bet. The
honest form is per-application, with the mechanism named. The yield stage measures `tsan-stmt` against
`tsan-stmt-yoff` on four applications, which isolates C1 (DynSTC across thread-free calls) and will say whether
that change moves the Redis loss or the FFmpeg gain — see `tools/notes/yield-stage-design-2026-09-08.md`.
