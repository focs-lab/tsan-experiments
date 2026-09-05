# P3 — shadow-eviction counters on SQLite threadtest3 (runtime hash tsan-audit a08292850aee)

Runtime commit 5eca63015f63 (compiler identical to 297881ddc1c5): `TSAN_OPTIONS=print_evictions=1` prints at exit
`shadow evictions total=N concurrent_foreign=M concurrent_foreign_plain=P` — total = overwrites of a full 4-slot
granule; concurrent_foreign = the overwritten record belonged to another thread and was not covered by the evicting
thread's clock (a race candidate lost); concurrent_foreign_plain = the same excluding evicted atomic accesses (mutex
interceptors' atomic reads dominate the uncovered evictions in lock-heavy code and cannot race with plain data).
`trace_evictions=1` adds one line per uncovered eviction (granule, evicting tid, evicted sid/epoch, atomic/plain,
read/write). Scripts: `run_sqlite.sh` (builds threadtest3 stock / tsan-sound / AllOpt+peel with the frozen copy,
N runs each, `results/<hash>/counters.txt`), `trace_sqlite.sh` (one traced run per config → `/extra/alexey/
tsan-experiments/eviction-traces/<hash>/`, 16–48 GB each), `attribute.sh` (counts the traced evictions on the
wal-index header granules named by the run's own race reports; note TSan prints mapped-file locations as
`<mapping base> (file+offset)`, so the granule is `(base+offset) & ~7`).

## Counters, N = 5 per configuration (three configurations run concurrently; threadtest3 subtests are time-bounded, so the amount of work per run varies with machine load)

| config | reports/run | evictions total (median, min–max, ×10⁹) | concurrent_foreign (×10⁹) | concurrent_foreign_plain (×10⁶) | plain/total |
|---|---|---|---|---|---|
| stock | 5.0 | 3.83 (3.03–4.95) | 0.95 (0.34–1.79) | 141 (64–325) | 3.5 % |
| tsan-sound | 5.0 | 3.38 (2.75–4.45) | 0.72 (0.19–1.62) | 132 (34–331) | 3.9 % |
| AllOpt+peel | 4.8 | 3.44 (2.61–4.32) | 0.78 (0.14–1.55) | 125 (31–296) | 3.6 % |

Run-to-run spread (×5 within a configuration) is far larger than any difference between configurations; the
counters do not separate the builds at N = 5 and would need normalisation by work done (ops/instrumented accesses)
to be comparable at all. Per-run lines: `results/a08292850aee/counters.txt`, stderr with reports in `run-<cfg>-<i>.err`.

## Attribution to the wal-index header (one traced run each; tracing slows the run, so absolute counts differ from above)

Granules of `test.db-shm` at +0x60 (`nBackfill`, `aReadMark[0]`; the `walTryBeginRead:68991` vs `walIndexRecover:67450`
race), +0x68 (`aReadMark[1..2]`) and +0x70 (`aReadMark[3..4]`; the `walRestartHdr` family):

| traced run | uncovered evictions, all granules | +0x60 atomic rd / at. wr / plain rd | +0x68 atomic rd / at. wr | +0x70 atomic rd / at. wr | wal-index share |
|---|---|---|---|---|---|
| stock | 435 571 480 | 1 930 / 95 / 466 | 65 238 / 4 465 | 23 676 / 205 | 96 075 (0.022 %) |
| AllOpt+peel | 141 272 140 | 3 646 / 142 / 700 | 130 118 / 4 807 | 83 693 / 278 | 222 684 (0.158 %) |

No plain *write* record on these granules was ever evicted uncovered in either run: the racy stores of
`walRestartHdr`/`walIndexRecover` survive; what gets evicted are the readers' atomic-load records of `aReadMark[i]`
(and, on +0x60, a few hundred plain reads). The optimized build evicts 2.3× more uncovered records on the wal-index
granules despite 3× fewer uncovered evictions overall — consistent with the P4 picture that removing traffic
elsewhere changes the victim arithmetic on the contended granule with no controlled direction — but this is one
traced run per build under tracing overhead, so it is an attribution, not a measurement of rate. The counters
mode (no trace) would need per-granule counters to quantify it.

## Per-granule rate, N = 10 (runtime hash 43111f84d936, `evict_watch`, non-tracing, ASLR off)

`watch_sqlite.sh`: threadtest3 stock / tsan-sound / AllOpt+peel built with the frozen 43111f84d936 copy; a calibration
run under `setarch -R` gives the wal-index mapping base from the run's own report (`0x7ffff7e17000` in every run of
every build), then 10 runs per build with `evict_watch=<base+0x60>+<base+0x68>+<base+0x70>`. Medians over 10 runs
(`results/43111f84d936/watch.txt`; total / uncovered (concurrent_foreign) / uncovered-plain per granule):

| config | reports/run | all granules total (×10⁹) | +0x60 (`nBackfill`, `aReadMark[0]`) | +0x68 (`aReadMark[1..2]`) | +0x70 (`aReadMark[3..4]`) |
|---|---|---|---|---|---|
| stock | 3.7 | 2.74 | 39008 / 2220 / 612 | 653104 / 70282 / 0 | 224874 / 24346 / 0 |
| tsan-sound | 3.8 | 2.83 | 38462 / 2181 / 584 | 656228 / 68186 / 0 | 225423 / 24561 / 0 |
| AllOpt+peel | 4.1 | 2.74 | 38080 / 2206 / 590 | 642671 / 68868 / 0 | 220406 / 25043 / 0 |

On the racing granules the three builds evict at the same rate (within 3 % on every counter): ~2 200 uncovered records
per run on the `nBackfill`/`aReadMark[0]` word, ~590 of them plain (the `walIndexRecover` write vs `walTryBeginRead`
read family), ~70 000 and ~25 000 uncovered atomic-read records on the read-mark words, and no uncovered plain record
at all on those two. The 2.3× difference seen in the single traced runs above was tracing overhead, not the builds:
the optimized builds neither increase nor decrease shadow eviction on the granules where TSan reports races here.
Together with the report frequencies (fifth wal-index site 3–7/10 in every build across rounds) this is the
measured answer to the bounded-shadow question for SQLite: eviction on the racing granules is a property of the
workload and the runtime, unchanged by the instrumentation removed elsewhere.

## memcached `current_time` granule (runtime hash 43111f84d936, `evict_watch`, N = 5, ASLR off)

`watch_memcached.sh`: memcached stock / tsan-sound / tsan-all (AllOpt+peel) built with the frozen copy, paper memtier
workload, address of the global `current_time` from a calibration run's report. Medians over 5 runs
(`results/43111f84d936/watch-memcached.txt`):

| config | reports/run | all granules: total / uncovered / uncovered-plain (×10⁹) | `current_time` granule: total / uncovered / uncovered-plain |
|---|---|---|---|
| stock | 10.2 | 9.09 / 2.43 / 2.36 | 41.6 M / 41.6 M / 41.6 M |
| tsan-sound | 10.4 | 9.07 / 2.43 / 2.36 | 39.0 M / 39.0 M / 39.0 M |
| AllOpt+peel | 13.2 | 9.06 / 2.44 / 2.38 | 38.6 M / 38.6 M / 38.6 M |

The `current_time` word (one writer per second, read on every request by every worker) is evicted ~40 million times
per run in every build, every eviction uncovered and plain, within 7 % across builds; ~1.7 % of all uncovered
evictions land on this one granule. So the `conn_new:761` pair moving between builds is not a change in how often
that granule forgets records; with the writer's record surviving equally, which reader is named in the report is
decided by timing (connection setup vs the once-per-second store), as the L3-level preservation shows.

## Evicted records by kind (answer to "was a racing write's record ever evicted uncovered?")

Uncovered evictions on the racing granules, split by the kind of the *evicted* record (`trace_evictions=1`):

| trace | plain read | atomic read | atomic write | **plain write** |
|---|---|---|---|---|
| SQLite wal-index header (+0x60/+0x68/+0x70), stock, 1 run | 466 | 90 844 | 4 765 | **0** |
| same, tsan-sound, 1 run | 637 | 227 492 | 4 574 | **0** |
| same, AllOpt+peel, 1 run | 700 | 217 457 | 5 227 | **0** |
| memcached `current_time` word, stock, short run (memtier 20 k requests/thread) | 859 538 | 0 | 0 | **0** |
| same, tsan-sound | 1 466 441 | 0 | 0 | **0** |
| same, AllOpt+peel | 1 114 765 | 0 | 0 | **0** |

In every build and both applications the evicted uncovered records on the racing granules are reader records (plus,
on SQLite, the `AtomicStore` records of `nBackfill`/`aReadMark`); no record of a racing plain write
(`walRestartHdr`/`walIndexRecover` stores, `clock_handler`'s store to `current_time`) was ever evicted uncovered.
Plain-read records *are* evicted, so "no racing plain access" would be wrong; "no racing write" holds. Caveat: one
traced run per build for SQLite (full workload) and one short traced run per build for memcached (a few seconds,
a handful of `clock_handler` ticks); the writer's record on `current_time` also disappears through TSan's
post-report clearing, which is not an eviction. Traces: `/extra/alexey/tsan-experiments/eviction-traces/`.

## Compiler copy for these measurements (2026-09-05)

From stage-b on, the eviction counters exist only in the counters-ON copy `/extra/alexey/builds/tsan-perf-d3bf9f8c39fe-evictstats/` (`COMPILER_RT_TSAN_EVICTION_STATS=ON`); the performance copy `tsan-perf-d3bf9f8c39fe` prints nothing under `print_evictions=1`. Point every P3 run at the `-evictstats` copy; it has no `opt`.
