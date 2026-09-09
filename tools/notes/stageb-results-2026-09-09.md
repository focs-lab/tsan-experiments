# Stage B: the five applications re-measured on the performance compiler

**Compiler** `/extra/alexey/builds/tsan-perf-d3bf9f8c39fe` (counters OFF) · **N = 5** per row, pinned to
`4-27,60-83`, one measurement at a time under the machine job lock · **tree**
`tools/perf/results/stageB-d3bf9f8c39fe` · finished 2026-09-09 05:45.

500 clean runs across 69 configuration rows; 39 runs retired and re-run, 9 of them by the foreign-activity gate
tightened from 0.25 to 0.10 partway through (`tools/notes/foreign-load-bands-2026-09-08.md`). Every row of every
application reached five clean repetitions.

## Instrumented TSan against native

| application | native / stock TSan |
|---|---|
| memcached | 2.83 [2.67, 3.02] |
| FFmpeg | 2.81 [2.72, 2.83] |
| SQLite | 3.18 [2.94, 3.48] |
| Redis | 7.93 [7.75, 8.15] |
| MySQL | 10.84 [9.87, 11.73] |

## What any optimisation is worth: five rows out of 69

Only these intervals exclude 1.0. Everything else — every single analysis, every bundle, whole-program
summaries, thread-free names, peeling — straddles it on every application.

| application | configuration | speedup vs stock TSan |
|---|---|---|
| FFmpeg | DynSTC | **1.113 [1.097, 1.124]** |
| Redis | AllOpt+peel, whole-program summaries | 1.027 [1.008, 1.051] |
| Redis | dominance elimination | 1.020 [1.002, 1.045] |
| Redis | DynSTC | **0.969 [0.950, 0.990]** |
| SQLite | DynSTC (resolvable subtests) | **0.983 [0.978, 0.995]** |

The three bold rows are the same lever pointing in three directions; the mechanism and the evidence for it are
in `tools/notes/dynstc-sign-flip-2026-09-08.md`. The two Redis gains are real but small, and they are the only
places in the campaign where an analysis beat stock TSan outside the noise.

## What the data can and cannot resolve

Resolution differs by an order of magnitude between applications, which is itself a result: a campaign that
reported only point estimates would have read the same across all five.

| application | median 95 % interval width | pooled subtest noise |
|---|---|---|
| FFmpeg | 1.9 pp | 0.2-1.8 % (all four codecs) |
| Redis | 4.3 pp | 18 of 19 subtests under 5 % |
| SQLite | 17.8 pp, or ~2 pp over the four resolvable subtests | `stress1` 19.9 %, `dynamic_triggers` 16.1 %, `stress2` 5.5 % |
| memcached | 11.3 pp | single test |
| MySQL | ~11 pp | every script 4.1-8.6 %, so no restricted column is reported |

memcached and MySQL cannot resolve the 1-4 % effects at issue and should be reported as such rather than as
null results. The restricted column exists only where at least half the subtests survive the pooled-noise
filter; for MySQL it is deliberately suppressed, since with one script left it would measure a different
quantity rather than the same one more precisely.

## The yield copy adds nothing (measured after this leg)

The seven yield changes were measured as A/B pairs inside `tsan-yield-d98873cda906`, four applications, nine
rows each, N = 5. None of the sixteen pairs has an interval excluding 1.0, and the tightest bound is FFmpeg's
sound pair at 1.000 [0.992, 1.008]. FFmpeg also reproduces the DynSTC gain at 1.114 and 1.105 on that compiler
against 1.113 here, which is an independent replication of the campaign's one substantial result across two
separately built compilers. See `tools/notes/yield-stage-design-2026-09-08.md`.

## Provenance and caveats

- Powersave governor, turbo off, but the busy-core clock is pinned at 2.9 GHz whenever there is work
  (median flat at 2900 MHz over 2220 samples in 19.8 h), so the regime label is provenance, not a caveat on the numbers.
- The leg carries a common-mode drag of order 1 % from runs in the 0.05-0.10 foreign-activity band. Run-major
  ordering puts a configuration and its baseline in adjacent minutes, so it largely cancels in the ratios.
- SD (slowdown vs native) rows are sound here: unlike Stage A on 729521af8965, this compiler has the eviction
  counters off, so both sides share the runtime.
- Chromium is not in this tree. It remains twelve builds of about six hours plus roughly six days of
  benchmarking, and it is not scheduled.

## Closed decision: memcached does not get more repetitions

Left open on 2026-09-08, decided on the finished leg. memcached's pooled run-to-run CV is 2.9 % over its 16
configurations, and its interval width scales as 1/sqrt(N):

| N | expected 95 % width | machine hours (16 configurations) |
|---|---|---|
| 5 (measured) | 7.1 pp | 4 |
| 10 | 5.1 pp | 8 |
| 20 | 3.6 pp | 16 |
| 40 | 2.5 pp | 32 |
| 160 | 1.3 pp | 128 |

The effects at issue are 1-4 %. Reaching a width that could resolve a 2 % effect needs N of about 80, which is
64 hours of machine time for one application, and even N = 40 at 32 hours only reaches 2.5 pp. Doubling to
N = 10 costs four more hours and still cannot separate any configuration from stock. So memcached stays at
N = 5 and is reported as unresolved rather than null, and the same reasoning applies to MySQL, whose runs are
five times longer.

The cheap gains were taken instead and they were larger than more repetitions would have been: retiring the
seven contaminated runs cut memcached's per-configuration CVs from double digits to 0.3-4.3 % and its interval
widths from about 24 pp to 11 pp, for half an hour of re-measurement.
