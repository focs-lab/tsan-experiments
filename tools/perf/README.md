# tools/perf — performance re-measurement (P5) of every configuration on the final compiler

## Method (Stage A, methodology pass — for approval)

- **Compiler**: the tsan-dev tip, frozen self-contained copy `/extra/alexey/builds/tsan-dev-<hash>/`
  (`clang --version` stamp = code; `TSAN_AUDIT_HASH`, `CONSOLIDATED_HASH`). Every binary's `build_info.txt`
  records the stamp, flags and summaries; `static-counts.csv` records its memory-access instrumentation sites.
- **Configurations** (`configs.sh`): `orig` (native), `tsan` (stock TSan), `tsan-sound` (EA+LO+STC+SWMR),
  `tsan-dom-ea-lo-st-swmr` (**AllOpt−peel**), `tsan-dom_peeling-ea-lo-st-swmr` (**AllOpt+peel**, the paper's AllOpt),
  and `…-wp` = the same build with the sound whole-program summaries (memcached, Redis, SQLite). Per-unit
  analyses otherwise. Stage B adds the single analyses (`tsan-st`, `-stmt`, `-swmr`, `-lo`, `-ea`, `-dom`,
  `-dom_peeling`) and `tsan-sound-wp`.
- **Workloads** = the paper's benchmark scripts, unchanged except for repetition and output-path plumbing:
  memcached memtier (`-t 10 -x 5 --pipeline 16 -P memcache_text --random-data`, server `-t <cpus>`), Redis
  `redis-benchmark -P 1024` over the 19 tests (`orig` now runs the same request count as the others), SQLite
  `threadtest3` (all subtests, 20 s each), MySQL sysbench (5 scripts, `--time=60` in Stage A / 180 in Stage B,
  threads = ¾ of the CPUs), FFmpeg 4 encodes of the paper's input.
- **Machine**: 112-CPU (56-core) Xeon w9-3495X, 250 GB. Benchmarks are pinned with `taskset` to a fixed set of
  48 CPUs (cores 4–27 + SMT siblings), one benchmark at a time, no build running meanwhile (shared lock). The
  `bench` reservation script is used only when another user already holds one (then everything outside is on
  8 CPUs). Each run records cpuset, governor/turbo, load and the *foreign* CPU share (machine busy time not
  ours, over the run); a run above `P5_FOREIGN_MAX` (0.15) is marked disturbed and re-run at the end of the
  sweep, never averaged. Disturbance is judged on the CPUs *outside* the pinned set, where nothing of ours can
  run, so it does not depend on how completely `/usr/bin/time` accounts for our own processes (memcached's
  server starts outside the timed region; its ticks are added back explicitly). CPUs listed in
  `tools/perf/ignore_cpus` (or `$P5_IGNORE_CPUS`) are excluded from both sides — they hold our own parked
  background work, currently the MySQL escape-analysis build on 52-55,108-111, which is neither this run's
  work nor somebody else's interference.
- **Machine state during Stage A** (recorded in every `meta.json`): governor `powersave`, turbo enabled — the
  `bench` reservation, which pins the performance governor and disables turbo, is used only when another user
  holds one (Alexey's policy), so the clock policy is the machine's default and identical for all configurations.
  One single-threaded compile (the MySQL escape-analysis case under investigation,
  `tools/notes/ea-compile-time-2026-09-04.md`) was left running throughout, confined with `taskset` to CPUs
  52-55,108-111, outside both benchmark cpusets; it contributes < 1 % of the machine and shows up in the
  per-run foreign-CPU share. Because its process tree holds the shared build lock, the Stage A sweep used a
  separate lock file (`P5_LOCK=/tmp/p5-bench-stageA.lock`); no other build ran during the runs.
- **The SD column ("x native") on 729521af8965 is inflated and must not be quoted as an absolute.** The TSan
  runtime in this tree carries the eviction counters added for the P3 experiments (`NoteEviction`, commit
  fe1e4f609675): a locked increment on a process-global cache line at every shadow eviction, and — because the
  helper is an out-of-line call inside the inlined access check — three extra register saves on *every*
  `__tsan_read/write`, evictions or not. Measured against the paper compiler's runtime on SQLite threadtest3 the
  stock build is ~1.4x slower at 4 % more instrumentation (`tools/notes/sqlite-2.77x-not-reproducible-2026-09-05.md`);
  confirmed by `TSAN_OPTIONS=print_evictions=1` (3.0e8 evictions in a 10 s `checkpoint_starvation_1`). SU rows are
  unaffected to first order (both sides share the runtime; an optimised build evicts slightly less, so it pays
  slightly less — a few per cent of a few per cent, flattering). Stage B runs on the performance-branch copy
  with the counters off (hash to be announced by tsan-dev), which will produce the absolute column properly.
- **Provenance gate in the runner.** `bench_one.sh` refuses any binary whose `build_info.txt`
  `compiler_head` is not the sweep's hash (`P5_HASH`, exported by `run.sh`). Added after a one-off that skipped
  `build.sh` measured a 2026-09-02 pre-audit SQLite binary (0de7a7350375) as if it were 729521af8965 and
  produced a spurious "DE+Peeling alone 1.48x"; caught by the tsan-dev lane from the binary's stamp, withdrawn,
  the row quarantined. Every one of the 28 Stage A rows was then audited from `meta.json`: all 729521af8965.
- **Stage A's EA-containing rows carry a known soundness hole** (reported by tsan-dev, 2026-09-05): in the
  escape summaries, a callee that stores its argument through another argument was reported non-escaping to
  callers, so a small number of accesses were elided that a sound analysis keeps. Every `tsan-sound` and AllOpt
  row on 729521af8965 contains EA and is therefore very slightly flattering to the optimised configurations —
  in the same direction as, and of the same order as, the eviction-counter nuance above. Fixed on the
  performance branch; Stage B's EA rows measure a sound compiler.
- **Chromium (Telemetry) needed four fixes before a single story ran on an instrumented build** (2026-09-05): a
  private Xvfb display always (an SSH-forwarded `DISPLAY` inherited by a detached run made chrome never come up),
  `depot_tools` on `PATH` (the runner is `#!/usr/bin/env vpython3`; a clean launch environment failed every run
  with rc=127), Telemetry's browser-startup timeout raised from 60 s to 600 s in the checkout's
  `browser_options.py` (it has no CLI flag; a TSan chrome pinned to 16 CPUs never exposed DevTools in 60 s and
  every story "failed" in 226 s with no browser), and the suites pinned to the same 48 CPUs as every other
  application instead of 16 (March ran unpinned on 112). Validated on one story (`Cowboy`, stock TSan: OK in
  27 s, 955 ms) before the suites were started. The patched files are in `chromium/files_with_fixed_timeout/`.
- **Chromium in Stage A is stock TSan only.** The `tsan-sound` Chromium build hit the escape-analysis
  compile-time cliff (`vk_safe_struct_utils.cpp`, one translation unit, stopped after 4 h 24 min) and was
  abandoned on 729521af8965; every EA-containing Chromium configuration is measured in Stage B on the stage-b
  copy, where the fixpoint fix removes the cliff and the runtime is byte-identical to upstream. Stage A's
  Chromium leg therefore validates the pipeline (2 suites x 2 reps on the stock build; one SVG story,
  `SierpinskiCarpet`, exceeds Telemetry's 10-minute per-story cap under TSan and is absent from that suite's
  rows) rather than producing a speedup row.
- **Provenance of Stage A binaries.** The memcached, Redis and SQLite build scripts archived only paper-era
  builds and overwrote everything else, so the 729521af8965 binaries of those three were replaced when Stage B
  built on d3bf9f8c39fe (their sha256 and stamps remain in every run's `meta.json`, and any of them can be
  rebuilt from the frozen copy — the Redis sound one was, as `redis-sound-h729`, for a per-function diff).
  All five build scripts now archive a build of another stamp as `old-builds/<dir>.<stamp>` and delete only a
  same-stamp rebuild, which is what CLAUDE.md required.
- **Untested in Stage A**: the bench-reservation path (`bench_session.sh`, tmux + `bench -c … -m …`). It is
  implemented and the driver switches to it when another user's `bench-*` unit is active, but exercising it
  confines every other session on the machine to 8 CPUs, so it was not run during Stage A. It needs one quiet
  window with a 2-CPU reservation before Stage B relies on it.
- **Repetitions**: run-major order (run 1 of every configuration, then run 2, …) so drift affects all
  configurations alike; N = 3 in Stage A, 5 in Stage B. memtier's own 5 iterations inside one memcached run are
  the paper's setting and count as one run.
- **Statistics** (`aggregate.py`): per (configuration, test) the median, mean ± sample σ and CV over the
  undisturbed runs; speedup vs stock TSan (SU) and slowdown vs native (SD) on medians per test, combined as the
  geometric mean over the app's tests (Redis 19, SQLite 7, FFmpeg 4 codecs, MySQL 5 scripts, memcached 1),
  with a 95 % bootstrap interval over run resamples; static sites joined from `static-counts.csv`.
  Parsers are the repo's own (`analyze_results_redis.parse_results`, `sql/sqlite/parse_results.parse_log_file`,
  `ffmpeg_contention_report.load_summary_csv`), memcached's `Totals` line and MySQL's `total:` queries as the
  legacy shell parsers read them — checked against the March artefacts (`check_parsers`).

## Usage

    ./build.sh <app> <hash> [cfg ...]           # builds (concurrent across apps, throttled, waits for benches)
    ./run.sh <app> <hash> [N] [--configs "..."] # N repetitions, pinned; --cpuset, --in-bench
    ./aggregate.py results/<date>-<hash>        # perf_<app>.{md,csv,json}, perf_summary.md
    ./cleanup_archive.sh                         # archive stale trees to /extra (done 2026-09-04: 100 -> 153 GB free)

Results root: `results/<date>-<hash>/` (git-ignored): `build/`, `static-counts.csv`, `<app>/<cfg>/run<k>/`
(raw artefact + `meta.json`), `<app>/session.json`, `<app>/runs.log`.

## Results

### Interference pilot (2026-09-04, 729521af8965) — parallel benchmarking rejected

memcached (`tsan`, `tsan-sound`), N = 3, alone on CPUs 4-27,60-83 versus the same while SQLite `tsan` ran on the
disjoint set 28-51,84-107 (`results/2026-09-04-729521af8965-pilot/pilot.md`):

| phase | config | N | median ops/s | mean | σ | CV |
|---|---|---|---|---|---|---|
| alone | tsan | 3 | 370118 | 349581 | 36921 | 10.6 % |
| alone | tsan-sound | 3 | 288867 | 289174 | 3283 | 1.1 % |
| paired | tsan | 3 | 359509 | 355561 | 9336 | 2.6 % |
| paired | tsan-sound | 3 | 351132 | 332658 | 42615 | 12.8 % |

The ratio tsan-sound/tsan is 0.780 alone and 0.977 paired — a 25 % difference, larger than the run-to-run
spread. **Benchmarks are therefore run one at a time**, as the default policy already assumed; the disjoint-cpuset
pairing is not used, and Stage B keeps the same rule.

### Open methodology question: memcached run-to-run bimodality

Across the 16 pilot runs the memcached workload lands in one of two states, and this dominates every effect we
want to measure (each run is memtier's own average over 5 iterations of 5 M requests):

| state | wall time | throughput |
|---|---|---|
| fast | 85-88 s | 345-372 k ops/s |
| slow | 100-108 s | 283-307 k ops/s |

It is not foreign load (the slowest-throughput run had the *lowest* outside-CPU busy share, 0.088, and the
0.579 outlier was mid-range), not NUMA (one node) and not the configuration (both states occur for `tsan` and
for `tsan-sound`). The likely cause is the workload's own placement: 48 server threads and 10 client threads
with 500 connections share the same 48 pinned CPUs, so a run settles into one equilibrium or the other. With a
~10 % CV and only ~2 % fewer instrumentation sites between `tsan` and `tsan-sound` (6748 → 6601), N = 3 medians
cannot resolve memcached. Options, for Alexey to choose: raise N for memcached only (a run is ~90 s, N = 10 costs
15 minutes per configuration), give client and server disjoint CPU subsets (changes the paper's setup), or run
the memcached rows under a `bench` reservation (performance governor, no turbo — but it confines every other
session on the machine to 8 CPUs). The other four applications are single-process or long-running and do not
show this.

_(Stage A per-application tables are appended here as each application completes.)_

### FFmpeg: one of the four codecs is too short to carry a quarter of the geometric mean

`copy_passthrough` is a stream copy: 0.88-1.00 s per run under stock TSan, 0.27 s native. Its run-to-run
spread is ~13 % and it contributes one quarter of the FFmpeg geometric mean in log space, which is why
`tsan-sound` shows 0.871 overall while its three real encodes are 0.94, 1.05 and 1.00. The paper's FFmpeg
column has the same structure (March: mjpeg 2.96, copy 1.51, x264 1.03, x265 1.02). Either drop it from the
geometric mean or give it enough work to measure — but say which, because it moves the headline by ~10 %.

### SQLite: the paper's 2.77x is not a machine-width effect (probe, 2026-09-04)

`sqlite_cpuscale_probe.sh` ran stock TSan and AllOpt-peel at 48 and at 96 pinned CPUs, N = 2
(`results/2026-09-04-729521af8965-cpuscale/cpuscale.md`): geometric mean **1.038 at 48 CPUs, 0.991 at 96**.
Doubling the width does not recover 2.773, and on `stress1` — the subtest that carries the paper's SQLite
geometric mean — stock TSan gets *faster* with more CPUs (84 076 -> 97 895 iterations), the opposite of the
contention explanation. Ruled out for the March/now gap, in order: subtest durations (identical, 10 s),
build flags (the March-era script at git 0632e34 has the same `-g -O2 -fno-omit-frame-pointer` and SQLite
3500200), race reports (none in either, `report_bugs=0` in both), machine width (this probe). What remains is
the compiler that produced the *stock TSan baseline*: March's `tsan` did 6 417 `stress1` iterations in 10 s
where today's does 84-105 k, while native differs by only 1.2x. `sqlite_baseline_probe.sh` builds both
configurations with both compilers (paper e90a3fc41004 and final 729521af8965) and measures all four in one
window; if the paper compiler reproduces ~6 k, the published ratios are against a pathological reference and
the speedup shrank because the baseline improved, not because the analyses weakened.

### The workload's thread and CPU count decides the answer, not only the compiler

Three of the five applications take a thread or CPU count from the environment, and in all three the paper's
value differs from "one per pinned CPU", which is what this driver used at first. The effect is larger than
every compiler effect being measured:

| application | knob | paper / March | Stage A first pass | consequence |
|---|---|---|---|---|
| FFmpeg | `-threads` (`FFMPEG_BENCH_NPROC_COUNT`) | 4 | 48 | **h265 fails on every build** (libx265 caps frame threads at 16) and vanishes from the tables; mjpeg under stock TSan goes from 76 s to 202 s |
| memcached | `memcached -t` | `nproc` = 112, unpinned | 48 | native throughput 914 k ops/s vs 5.08 M |
| SQLite | machine width (`threadtest3` is unpinned) | 112 CPUs | 48 | stock TSan is 34.8x native on `stress1` in March, 3.1x here — and `stress1` carries the paper's SQLite geomean |

FFmpeg is therefore re-measured at the paper's 4 threads (`FF_THREADS`, default 4 in `bench_one.sh`); the
48-thread pass is kept as `ffmpeg-threads48/` because it is the evidence for the sensitivity. The SQLite
CPU-count probe (`sqlite_cpuscale_probe.sh`, 48 vs 96 CPUs) measures the third row directly.

**This is the decision to take before Stage B**: either reproduce each application's paper-era setting exactly
(comparable to the submitted tables, but the settings are arbitrary and partly accidental), or fix one policy
for all five applications (defensible, but no row can be compared to March). Whichever is chosen, the setting
belongs in the method text, because at these effect sizes it matters more than the analyses do.

### Chromium, Stage A (stock TSan only, 2026-09-05)

`chromium/run_all_chrome_bench.sh`, build `chrome-tsan` (729521af8965), suites `blink_perf.svg` and
`speedometer3`, 2 repetitions, 48 pinned CPUs, private Xvfb; folded by
`tools/chrome-result-processing/aggregate_reps.py` into `/extra/alexey/chromium/results-729521af8965/csv/`.

| suite | rows (story x label) | rep-to-rep CV median | max | wall per rep |
|---|---|---|---|---|
| blink_perf.svg | 21 (of 23 stories; `SierpinskiCarpet` over the 10-min cap both reps) | 2.1 % | 15.1 % | 33-40 min |
| speedometer3 | 20 | 11.2 % | 28.2 % | 42-51 min |

Against the March stock-TSan rows of the same suite (`tools/chrome-result-processing/csv/`), the 21 shared SVG
stories are **1.26x slower now** (median; range 1.07-1.35): the eviction-counter tax again, on a browser this
time. Speedometer's rep-to-rep spread (11 % median) says N = 2 is not enough for that suite; Stage B's N = 3
is the minimum, and per-story medians rather than a single score should be reported.

### Stage B compiler acceptance (2026-09-05)

Frozen copy `/extra/alexey/builds/tsan-perf-d3bf9f8c39fe/` (perf/stage-b: runtime counters off, hot symbols
byte-identical to upstream; EA fixpoint fix; lost-race shapes 18-21). All Stage A configurations of the five
applications rebuilt with `build.sh` into `results/stageB-d3bf9f8c39fe/`; static-count diff against
729521af8965 with `static_diff.py`, attributed line by line with tsan-dev, in
`tools/notes/stageb-acceptance-2026-09-05.md`. Accepted on all five applications (2026-09-05 13:07): stock rows
identical; EA rows +0.06 % (SQLite) to +1.65 % (MySQL), every increase attributed to the soundness shapes
(19: address of a local passed to a bodiless or `linkonce_odr` pointer-returning callee; recovered by the
whole-program summaries where the callee is in the linked IR — Redis +1.3 % → +0.4 %). MySQL's `sql_yacc.cc`
compiles in ~20.5 min (3 h 02 min on 729521af8965). Chromium is *not* accepted on this copy: its
`vk_safe_struct_utils.cpp` is a second compile-time cliff, fixed in the next copy; every EA-containing
Chromium row waits for it. No benchmark has run on this copy yet.

### Stage B decisions (Alexey, 2026-09-05: "measure what performs best"; operational points mine)

1. **Thread/CPU policy.** Every workload keeps the *paper's derivation rule* applied to the pinned machine:
   fixed values stay fixed (FFmpeg `-threads 4`), values the paper derived from `nproc` are derived from the
   48 pinned CPUs (memcached `-t 48`, sysbench 36 threads). Because the answer to "which performs better" is
   empirical, memcached and MySQL get a **thread-policy pilot** first (stock and sound only, N = 3, the
   paper-era count 112 / 84 against the pinned 48 / 36); if the paper-era count yields materially larger
   speedups, Stage B adopts it for that application and says so.
   **Pilot result (2026-09-07, d3bf9f8c39fe, N = 3):** the policy does not matter — memcached sound/stock 1.008
   (pinned, `-t 48`) vs 1.004 (paper, `-t 112`), MySQL 1.014 vs 1.014 (36 vs 84 sysbench threads). **Stage B
   runs the pinned rule.** Side finding: with the eviction counters off, memcached's run-to-run CV is 3.6-3.8 %
   (10-12 % on 729521af8965) and stock throughput 2.1 M ops/s (0.36 M): the bimodality was the runtime tax.
2. **memcached** runs N = 10 (a run is ~100 s) at the paper-derived setting, unchanged client/server sharing,
   so the workload stays the paper's and the ±10 % run-to-run spread is averaged rather than redesigned.
3. **FFmpeg** keeps the paper's four codecs in the run; the headline geometric mean **excludes**
   `copy_passthrough` (0.9 s, ~13 % spread on its own) and the table shows the four-codec mean beside it.
4. **STC lever.** Both: whole-program-summaries rows (`tsan-sound-wp`, AllOpt+peel WP) and, where the
   compiler lane supplies a safe name list, `-tsan-thread-free-names` rows; the plain sound rows use neither.
5. **Yield copy** `tsan-yield-fdf7a4dd41e9` is in scope: the main rows (tsan, sound, AllOpt±peel, DynSTC) on
   all five applications at N = 5, compared with the stage-b copy; per-switch A/B only where a total moves.
6. **Memory caps** (machine rule after the 5-6 Sep outage; `user.slice` has a shared MemoryHigh of 110 GiB for
   every account, no swap): every build runs in a `systemd-run --user --scope -p MemoryMax=` scope (MySQL 48G,
   FFmpeg 24G, others 8G; MySQL launched alone) and every measurement in a 32G scope — sized from observed peaks
   (≤ 1.8 GB timed tree, 6.6 GB per Chromium renderer), binding below the shared limit, never `bench`.
7. Other Stage A settings stand: 48 pinned CPUs, one benchmark at a time, run-major, disturbance judged on
   the outside CPUs (threshold 0.25), provenance gate on every binary, N = 5 elsewhere, MySQL sysbench 180 s.

<!-- P5-TABLES-START -->

### Tables — 2026-09-04-729521af8965

Generated by `aggregate.py` from `results/2026-09-04-729521af8965/`; regenerate with `python3 write_readme_results.py results/2026-09-04-729521af8965`.

#### Cross-application summary

SU = speedup vs stock TSan, SD = slowdown vs native; geometric mean over the app's tests on per-test medians of N undisturbed runs; [95 % bootstrap interval].

| app | config | label | N | SU | SD | static sites | modes |
|---|---|---|---|---|---|---|---|
| sqlite | orig | orig | 3 | 3.784 [3.616, 3.997] | — | 0 | pinned |
| sqlite | tsan | tsan | 3 | — | 3.78 [3.62, 4.00] | 57996 | pinned |
| sqlite | tsan-dom-ea-lo-st-swmr | AllOpt-peel | 3 | 1.051 [1.009, 1.118] | 3.60 [3.44, 3.72] | 56054 | pinned |
| sqlite | tsan-dom_peeling | tsan-dom_peeling | 3 | 1.015 [0.970, 1.119] | 3.73 [3.42, 3.86] | 62996 | pinned |
| sqlite | tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 3 | 1.020 [0.929, 1.144] | 3.71 [3.34, 4.06] | 61895 | pinned |
| sqlite | tsan-dom_peeling-ea-lo-st-swmr-wp | AllOpt+peel (WP summaries) | 3 | 1.007 [0.950, 1.077] | 3.76 [3.56, 3.97] | 61791 | pinned |
| sqlite | tsan-dom_peeling.STALE-0de7a7350375 | tsan-dom_peeling.STALE-0de7a7350375 | 3 | 1.478 [1.334, 1.576] | 2.56 [2.44, 2.82] | — | pinned |
| sqlite | tsan-sound | tsan-sound | 3 | 0.998 [0.932, 1.091] | 3.79 [3.51, 4.05] | 56992 | pinned |

#### ffmpeg

Session: mode=pinned cpuset=4-27,60-83 governor=powersave no_turbo=0 host=focs-server started=2026-09-05T03:57:57

| config | N | h264_libx264 median (mean ± σ, CV) | copy_passthrough median (mean ± σ, CV) | mjpeg median (mean ± σ, CV) | h265_libx265 median (mean ± σ, CV) |
|---|---|---|---|---|---|
| orig | 3 | 42.27 (42.31 ± 0.091, 0.2 %) | 0.14 (0.1433 ± 0.0058, 4.0 %) | 4.12 (4.127 ± 0.031, 0.7 %) | 42.37 (42.33 ± 0.081, 0.2 %) |
| tsan | 3 | 53.94 (54.05 ± 0.51, 0.9 %) | 0.87 (0.8767 ± 0.012, 1.3 %) | 208.8 (220 ± 27, 12.2 %) | 164.4 (162.3 ± 4.7, 2.9 %) |
| tsan-dom-ea-lo-st-swmr | 3 | 54.18 (54.35 ± 0.78, 1.4 %) | 0.91 (0.92 ± 0.046, 5.0 %) | 204.4 (205.6 ± 2.1, 1.0 %) | 158.1 (159.5 ± 3.6, 2.3 %) |
| tsan-dom_peeling-ea-lo-st-swmr | 3 | 55.02 (69.91 ± 27, 39.3 %) | 0.89 (0.9967 ± 0.21, 21.2 %) | 256.3 (241.1 ± 33, 13.7 %) | 157.6 (157.9 ± 1.8, 1.2 %) |
| tsan-sound | 3 | 56.9 (63.83 ± 15, 23.1 %) | 1.52 (1.7 ± 0.37, 22.0 %) | 250.1 (238.6 ± 25, 10.5 %) | 158.6 (161.4 ± 5.6, 3.5 %) |

##### Speedup vs stock TSan (SU) and slowdown vs native (SD), on medians; geometric mean over tests; 95 % bootstrap interval

| config | label | N | SU geomean [95 %] | SD geomean [95 %] | static sites | modes | per-test SU |
|---|---|---|---|---|---|---|---|
| orig | orig | 3 | 6.284 [6.070, 6.619] | — | 0 | pinned | h264_libx264:1.28, copy_passthrough:6.21, mjpeg:50.68, h265_libx265:3.88 |
| tsan | tsan | 3 | — | 6.28 [6.07, 6.62] | 514609 | pinned |  |
| tsan-dom-ea-lo-st-swmr | AllOpt-peel | 3 | 1.003 [0.965, 1.061] | 6.27 [6.10, 6.45] | 473938 | pinned | h264_libx264:1.00, copy_passthrough:0.96, mjpeg:1.02, h265_libx265:1.04 |
| tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 3 | 0.950 [0.744, 1.063] | 6.62 [6.09, 8.39] | 541949 | pinned | h264_libx264:0.98, copy_passthrough:0.98, mjpeg:0.81, h265_libx265:1.04 |
| tsan-sound | tsan-sound | 3 | 0.828 [0.689, 0.918] | 7.59 [7.05, 9.06] | 496784 | pinned | h264_libx264:0.95, copy_passthrough:0.57, mjpeg:0.83, h265_libx265:1.04 |

#### memcached

Session: mode=pinned cpuset=4-27,60-83 governor=powersave no_turbo=0 host=focs-server started=2026-09-04T22:11:21

| config | N | ops_sec median (mean ± σ, CV) |
|---|---|---|
| orig | 3 | 4.76e+06 (4.967e+06 ± 4.5e+05, 9.1 %) |
| tsan | 3 | 3.681e+05 (3.676e+05 ± 6.1e+03, 1.7 %) |
| tsan-dom-ea-lo-st-swmr | 3 | 3.525e+05 (3.373e+05 ± 3.1e+04, 9.3 %) |
| tsan-dom_peeling-ea-lo-st-swmr | 3 | 2.961e+05 (3.121e+05 ± 3.7e+04, 11.9 %) |
| tsan-dom_peeling-ea-lo-st-swmr-wp | 3 | 2.903e+05 (3.104e+05 ± 4.2e+04, 13.7 %) |
| tsan-sound | 3 | 2.993e+05 (3.186e+05 ± 3.5e+04, 11.1 %) |

##### Speedup vs stock TSan (SU) and slowdown vs native (SD), on medians; geometric mean over tests; 95 % bootstrap interval

| config | label | N | SU geomean [95 %] | SD geomean [95 %] | static sites | modes | per-test SU |
|---|---|---|---|---|---|---|---|
| orig | orig | 3 | 12.929 [12.472, 15.180] | — | 0 | pinned | ops_sec:12.93 |
| tsan | tsan | 3 | — | 12.93 [12.47, 15.18] | 6748 | pinned |  |
| tsan-dom-ea-lo-st-swmr | AllOpt-peel | 3 | 0.958 [0.807, 0.991] | 13.50 [13.00, 18.20] | 6367 | pinned | ops_sec:0.96 |
| tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 3 | 0.804 [0.765, 0.981] | 16.07 [13.14, 19.19] | 7086 | pinned | ops_sec:0.80 |
| tsan-dom_peeling-ea-lo-st-swmr-wp | AllOpt+peel (WP summaries) | 3 | 0.788 [0.755, 0.994] | 16.40 [12.97, 19.46] | 6655 | pinned | ops_sec:0.79 |
| tsan-sound | tsan-sound | 3 | 0.813 [0.796, 0.995] | 15.90 [12.96, 18.45] | 6601 | pinned | ops_sec:0.81 |

#### mysql

Session: mode=pinned cpuset=4-27,60-83 governor=powersave no_turbo=0 host=focs-server started=2026-09-05T04:19:35

| config | N | oltp_read_only median (mean ± σ, CV) | oltp_read_write median (mean ± σ, CV) | oltp_write_only median (mean ± σ, CV) | select_random_points median (mean ± σ, CV) | select_random_ranges median (mean ± σ, CV) |
|---|---|---|---|---|---|---|
| orig | 3 | 3.423e+05 (3.61e+05 ± 4.6e+04, 12.7 %) | 3.627e+05 (3.639e+05 ± 8.3e+03, 2.3 %) | 4.561e+05 (4.629e+05 ± 1.7e+04, 3.6 %) | 1.501e+05 (1.482e+05 ± 6.6e+03, 4.4 %) | 2.893e+05 (2.899e+05 ± 6.3e+03, 2.2 %) |
| tsan | 3 | 3.293e+04 (3.363e+04 ± 1.4e+03, 4.0 %) | 2.669e+04 (2.667e+04 ± 2.2e+02, 0.8 %) | 3.701e+04 (3.704e+04 ± 8.2e+02, 2.2 %) | 1.329e+04 (1.296e+04 ± 5.7e+02, 4.4 %) | 2.184e+04 (2.193e+04 ± 3.2e+02, 1.5 %) |
| tsan-dom-ea-lo-st-swmr | 3 | 3.474e+04 (3.51e+04 ± 1.9e+03, 5.4 %) | 2.768e+04 (2.783e+04 ± 6e+02, 2.2 %) | 3.739e+04 (3.782e+04 ± 1.2e+03, 3.0 %) | 1.294e+04 (1.339e+04 ± 7.8e+02, 5.8 %) | 2.568e+04 (2.586e+04 ± 3.8e+02, 1.5 %) |
| tsan-dom_peeling-ea-lo-st-swmr | 3 | 3.334e+04 (3.361e+04 ± 6.4e+02, 1.9 %) | 2.737e+04 (2.829e+04 ± 2e+03, 7.1 %) | 3.649e+04 (3.703e+04 ± 1.3e+03, 3.6 %) | 1.376e+04 (1.345e+04 ± 6.4e+02, 4.7 %) | 2.513e+04 (2.513e+04 ± 1.3e+02, 0.5 %) |
| tsan-sound | 3 | 3.229e+04 (3.268e+04 ± 7.4e+02, 2.3 %) | 3.013e+04 (2.933e+04 ± 1.7e+03, 5.8 %) | 3.683e+04 (3.742e+04 ± 1.1e+03, 3.0 %) | 1.357e+04 (1.345e+04 ± 4.2e+02, 3.2 %) | 2.513e+04 (2.503e+04 ± 3e+02, 1.2 %) |

##### Speedup vs stock TSan (SU) and slowdown vs native (SD), on medians; geometric mean over tests; 95 % bootstrap interval

| config | label | N | SU geomean [95 %] | SD geomean [95 %] | static sites | modes | per-test SU |
|---|---|---|---|---|---|---|---|
| orig | orig | 3 | 12.111 [11.715, 12.865] | — | 0 | pinned | oltp_read_only:10.40, oltp_read_write:13.59, oltp_write_only:12.32, select_random_points:11.30, select_random_ranges:13.25 |
| tsan | tsan | 3 | — | 12.11 [11.72, 12.87] | 602434 | pinned |  |
| tsan-dom-ea-lo-st-swmr | AllOpt-peel | 3 | 1.048 [1.027, 1.099] | 11.55 [10.98, 12.17] | — | pinned | oltp_read_only:1.05, oltp_read_write:1.04, oltp_write_only:1.01, select_random_points:0.97, select_random_ranges:1.18 |
| tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 3 | 1.041 [1.009, 1.087] | 11.64 [11.13, 12.35] | — | pinned | oltp_read_only:1.01, oltp_read_write:1.03, oltp_write_only:0.99, select_random_points:1.04, select_random_ranges:1.15 |
| tsan-sound | tsan-sound | 3 | 1.053 [1.016, 1.084] | 11.50 [11.16, 12.27] | 587467 | pinned | oltp_read_only:0.98, oltp_read_write:1.13, oltp_write_only:0.99, select_random_points:1.02, select_random_ranges:1.15 |

#### redis

Session: mode=pinned cpuset=4-27,60-83 governor=powersave no_turbo=0 host=focs-server started=2026-09-04T18:30:26

| config | N | PING_INLINE median (mean ± σ, CV) | PING_MBULK median (mean ± σ, CV) | SET median (mean ± σ, CV) | GET median (mean ± σ, CV) | INCR median (mean ± σ, CV) | RPUSH median (mean ± σ, CV) | LPOP median (mean ± σ, CV) | RPOP median (mean ± σ, CV) | SADD median (mean ± σ, CV) | HSET median (mean ± σ, CV) | SPOP median (mean ± σ, CV) | ZADD median (mean ± σ, CV) | ZPOPMIN median (mean ± σ, CV) | LPUSH median (mean ± σ, CV) | LRANGE_100 median (mean ± σ, CV) | LRANGE_300 median (mean ± σ, CV) | LRANGE_500 median (mean ± σ, CV) | LRANGE_600 median (mean ± σ, CV) | MSET median (mean ± σ, CV) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| orig | 3 | 3.291e+06 (3.277e+06 ± 1.4e+05, 4.4 %) | 5.131e+06 (5.195e+06 ± 1.3e+05, 2.6 %) | 2.771e+06 (2.719e+06 ± 9.8e+04, 3.6 %) | 3.369e+06 (3.326e+06 ± 1.3e+05, 3.8 %) | 3.38e+06 (3.396e+06 ± 2.1e+05, 6.1 %) | 2.559e+06 (2.566e+06 ± 5.6e+04, 2.2 %) | 2.175e+06 (2.219e+06 ± 9.3e+04, 4.2 %) | 3.819e+06 (3.748e+06 ± 1.8e+05, 4.7 %) | 2.916e+06 (2.863e+06 ± 1.1e+05, 4.0 %) | 2.175e+06 (2.169e+06 ± 5.2e+04, 2.4 %) | 4.117e+06 (3.975e+06 ± 2.9e+05, 7.4 %) | 2.129e+06 (2.11e+06 ± 6.2e+04, 2.9 %) | 4.151e+06 (4.091e+06 ± 1.2e+05, 2.9 %) | 2.289e+06 (2.243e+06 ± 1.4e+05, 6.3 %) | 1.175e+05 (1.164e+05 ± 3e+03, 2.6 %) | 3.126e+04 (3.038e+04 ± 2.7e+03, 9.0 %) | 1.877e+04 (1.895e+04 ± 5e+02, 2.6 %) | 1.575e+04 (1.575e+04 ± 82, 0.5 %) | 4.743e+05 (4.812e+05 ± 1.5e+04, 3.2 %) |
| tsan | 3 | 3.521e+05 (3.521e+05 ± 3.7e+02, 0.1 %) | 5.5e+05 (5.446e+05 ± 3.4e+04, 6.2 %) | 2.521e+05 (2.532e+05 ± 5.7e+03, 2.3 %) | 3.295e+05 (3.28e+05 ± 3.4e+03, 1.0 %) | 3.243e+05 (3.16e+05 ± 1.9e+04, 5.9 %) | 2.052e+05 (2.02e+05 ± 6.5e+03, 3.2 %) | 1.802e+05 (1.813e+05 ± 3.6e+03, 2.0 %) | 3.705e+05 (3.695e+05 ± 7.1e+03, 1.9 %) | 2.769e+05 (2.806e+05 ± 2.2e+04, 7.7 %) | 2.059e+05 (2.059e+05 ± 3.9e+02, 0.2 %) | 4.026e+05 (4.018e+05 ± 5.4e+03, 1.3 %) | 2.159e+05 (2.14e+05 ± 6.9e+03, 3.2 %) | 3.9e+05 (3.891e+05 ± 3.3e+03, 0.9 %) | 1.735e+05 (1.73e+05 ± 6.2e+03, 3.6 %) | 2.048e+04 (2.049e+04 ± 3.7e+02, 1.8 %) | 7173 (7162 ± 32, 0.4 %) | 4354 (4330 ± 62, 1.4 %) | 3677 (3695 ± 31, 0.8 %) | 4.929e+04 (4.917e+04 ± 8e+02, 1.6 %) |
| tsan-dom-ea-lo-st-swmr | 3 | 3.463e+05 (3.451e+05 ± 9.2e+03, 2.7 %) | 5.506e+05 (5.503e+05 ± 1.7e+04, 3.1 %) | 2.491e+05 (2.514e+05 ± 4.6e+03, 1.8 %) | 3.243e+05 (3.242e+05 ± 4.4e+03, 1.3 %) | 3.047e+05 (3.124e+05 ± 1.5e+04, 4.8 %) | 2.026e+05 (2.019e+05 ± 3.3e+03, 1.7 %) | 1.799e+05 (1.806e+05 ± 3.1e+03, 1.7 %) | 3.643e+05 (3.64e+05 ± 4.2e+03, 1.1 %) | 2.795e+05 (2.759e+05 ± 1.1e+04, 4.1 %) | 2.131e+05 (2.162e+05 ± 9.1e+03, 4.2 %) | 3.968e+05 (3.963e+05 ± 1.5e+04, 3.7 %) | 2.212e+05 (2.234e+05 ± 5.1e+03, 2.3 %) | 4.05e+05 (4.131e+05 ± 1.4e+04, 3.4 %) | 1.75e+05 (1.757e+05 ± 8.3e+03, 4.7 %) | 2.096e+04 (2.132e+04 ± 6.6e+02, 3.1 %) | 7495 (7468 ± 1.2e+02, 1.5 %) | 4498 (4510 ± 35, 0.8 %) | 3831 (3798 ± 67, 1.8 %) | 5.218e+04 (5.11e+04 ± 2e+03, 3.9 %) |
| tsan-dom_peeling-ea-lo-st-swmr | 3 | 3.778e+05 (3.678e+05 ± 2.1e+04, 5.7 %) | 5.57e+05 (5.497e+05 ± 1.3e+04, 2.4 %) | 2.541e+05 (2.566e+05 ± 6.9e+03, 2.7 %) | 3.368e+05 (3.374e+05 ± 2.3e+03, 0.7 %) | 3.216e+05 (3.171e+05 ± 2.2e+04, 6.9 %) | 1.984e+05 (1.955e+05 ± 5.6e+03, 2.9 %) | 1.783e+05 (1.813e+05 ± 6.1e+03, 3.4 %) | 3.983e+05 (3.87e+05 ± 2.7e+04, 7.0 %) | 2.777e+05 (2.772e+05 ± 8.1e+03, 2.9 %) | 2.185e+05 (2.174e+05 ± 8.5e+03, 3.9 %) | 4.204e+05 (4.182e+05 ± 5.7e+03, 1.4 %) | 2.299e+05 (2.285e+05 ± 1.1e+04, 4.9 %) | 4.032e+05 (3.947e+05 ± 1.5e+04, 3.8 %) | 1.773e+05 (1.772e+05 ± 2.4e+03, 1.4 %) | 2.1e+04 (2.117e+04 ± 5.1e+02, 2.4 %) | 7492 (7473 ± 74, 1.0 %) | 4519 (4515 ± 82, 1.8 %) | 3818 (3824 ± 30, 0.8 %) | 5.093e+04 (4.971e+04 ± 2.2e+03, 4.3 %) |
| tsan-dom_peeling-ea-lo-st-swmr-wp | 3 | 3.539e+05 (3.55e+05 ± 1.4e+04, 3.8 %) | 5.646e+05 (5.669e+05 ± 1.1e+04, 2.0 %) | 2.499e+05 (2.522e+05 ± 7.7e+03, 3.0 %) | 3.306e+05 (3.318e+05 ± 7.2e+03, 2.2 %) | 3.152e+05 (3.14e+05 ± 8.7e+03, 2.8 %) | 2.078e+05 (2.072e+05 ± 1.7e+03, 0.8 %) | 1.893e+05 (1.881e+05 ± 5.3e+03, 2.8 %) | 3.665e+05 (3.69e+05 ± 1.1e+04, 2.9 %) | 2.856e+05 (2.806e+05 ± 9.8e+03, 3.5 %) | 2.203e+05 (2.213e+05 ± 2.2e+03, 1.0 %) | 4.141e+05 (4.139e+05 ± 6e+03, 1.4 %) | 2.221e+05 (2.238e+05 ± 4.9e+03, 2.2 %) | 4.007e+05 (4.042e+05 ± 1.2e+04, 2.9 %) | 1.773e+05 (1.776e+05 ± 3.4e+03, 1.9 %) | 2.11e+04 (2.099e+04 ± 3.6e+02, 1.7 %) | 7516 (7538 ± 77, 1.0 %) | 4609 (4578 ± 97, 2.1 %) | 3865 (3850 ± 38, 1.0 %) | 5.02e+04 (5.015e+04 ± 1.7e+03, 3.3 %) |
| tsan-sound | 3 | 3.564e+05 (3.558e+05 ± 4.2e+03, 1.2 %) | 5.476e+05 (5.434e+05 ± 3.4e+04, 6.3 %) | 2.524e+05 (2.554e+05 ± 7.6e+03, 3.0 %) | 3.308e+05 (3.29e+05 ± 7e+03, 2.1 %) | 3.112e+05 (3.204e+05 ± 1.7e+04, 5.5 %) | 2.051e+05 (2.021e+05 ± 6.1e+03, 3.0 %) | 1.859e+05 (1.873e+05 ± 3.7e+03, 2.0 %) | 3.764e+05 (3.775e+05 ± 6.6e+03, 1.7 %) | 2.909e+05 (2.931e+05 ± 5.2e+03, 1.8 %) | 2.238e+05 (2.177e+05 ± 1.1e+04, 5.1 %) | 4.049e+05 (4.046e+05 ± 4.2e+03, 1.0 %) | 2.41e+05 (2.348e+05 ± 1.2e+04, 5.1 %) | 4.023e+05 (4.037e+05 ± 1e+04, 2.6 %) | 1.736e+05 (1.731e+05 ± 4.5e+03, 2.6 %) | 2.035e+04 (2.027e+04 ± 1.4e+02, 0.7 %) | 7238 (7230 ± 1.3e+02, 1.8 %) | 4412 (4418 ± 19, 0.4 %) | 3697 (3712 ± 26, 0.7 %) | 5.158e+04 (5.062e+04 ± 2.1e+03, 4.1 %) |

##### Speedup vs stock TSan (SU) and slowdown vs native (SD), on medians; geometric mean over tests; 95 % bootstrap interval

| config | label | N | SU geomean [95 %] | SD geomean [95 %] | static sites | modes | per-test SU |
|---|---|---|---|---|---|---|---|
| orig | orig | 3 | 8.907 [8.696, 9.048] | — | 0 | pinned | PING_INLINE:9.35, PING_MBULK:9.33, SET:10.99, GET:10.22, INCR:10.42, RPUSH:12.47, LPOP:12.07, RPOP:10.31, SADD:10.53, HSET:10.57, SPOP:10.23, ZADD:9.86, ZPOPMIN:10.64, LPUSH:13.20, LRANGE_100:5.74, LRANGE_300:4.36, LRANGE_500:4.31, LRANGE_600:4.28, MSET:9.62 |
| tsan | tsan | 3 | — | 8.91 [8.70, 9.05] | 37941 | pinned |  |
| tsan-dom-ea-lo-st-swmr | AllOpt-peel | 3 | 1.009 [0.999, 1.031] | 8.83 [8.56, 8.92] | 36604 | pinned | PING_INLINE:0.98, PING_MBULK:1.00, SET:0.99, GET:0.98, INCR:0.94, RPUSH:0.99, LPOP:1.00, RPOP:0.98, SADD:1.01, HSET:1.04, SPOP:0.99, ZADD:1.02, ZPOPMIN:1.04, LPUSH:1.01, LRANGE_100:1.02, LRANGE_300:1.05, LRANGE_500:1.03, LRANGE_600:1.04, MSET:1.06 |
| tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 3 | 1.028 [1.006, 1.043] | 8.66 [8.48, 8.84] | 42725 | pinned | PING_INLINE:1.07, PING_MBULK:1.01, SET:1.01, GET:1.02, INCR:0.99, RPUSH:0.97, LPOP:0.99, RPOP:1.07, SADD:1.00, HSET:1.06, SPOP:1.04, ZADD:1.06, ZPOPMIN:1.03, LPUSH:1.02, LRANGE_100:1.03, LRANGE_300:1.04, LRANGE_500:1.04, LRANGE_600:1.04, MSET:1.03 |
| tsan-dom_peeling-ea-lo-st-swmr-wp | AllOpt+peel (WP summaries) | 3 | 1.024 [1.013, 1.043] | 8.70 [8.47, 8.78] | 40525 | pinned | PING_INLINE:1.00, PING_MBULK:1.03, SET:0.99, GET:1.00, INCR:0.97, RPUSH:1.01, LPOP:1.05, RPOP:0.99, SADD:1.03, HSET:1.07, SPOP:1.03, ZADD:1.03, ZPOPMIN:1.03, LPUSH:1.02, LRANGE_100:1.03, LRANGE_300:1.05, LRANGE_500:1.06, LRANGE_600:1.05, MSET:1.02 |
| tsan-sound | tsan-sound | 3 | 1.019 [1.004, 1.037] | 8.74 [8.53, 8.87] | 37123 | pinned | PING_INLINE:1.01, PING_MBULK:1.00, SET:1.00, GET:1.00, INCR:0.96, RPUSH:1.00, LPOP:1.03, RPOP:1.02, SADD:1.05, HSET:1.09, SPOP:1.01, ZADD:1.12, ZPOPMIN:1.03, LPUSH:1.00, LRANGE_100:0.99, LRANGE_300:1.01, LRANGE_500:1.01, LRANGE_600:1.01, MSET:1.05 |

#### sqlite

Session: mode=pinned cpuset=4-27,60-83 governor=powersave no_turbo=0 host=focs-server started=2026-09-05T05:32:47

| config | N | walthread1 median (mean ± σ, CV) | walthread2 median (mean ± σ, CV) | dynamic_triggers median (mean ± σ, CV) | checkpoint_starvation_1 median (mean ± σ, CV) | checkpoint_starvation_2 median (mean ± σ, CV) | stress1 median (mean ± σ, CV) | stress2 median (mean ± σ, CV) |
|---|---|---|---|---|---|---|---|---|
| orig | 3 | 5200 (5174 ± 1e+02, 1.9 %) | 1.454e+04 (1.455e+04 ± 96, 0.7 %) | 4.138e+05 (4.105e+05 ± 3.5e+04, 8.6 %) | 6.107e+05 (6.066e+05 ± 1.9e+04, 3.2 %) | 782 (782 ± 0, 0.0 %) | 2.691e+05 (2.782e+05 ± 1.9e+04, 6.8 %) | 1.545e+05 (1.548e+05 ± 1.3e+03, 0.8 %) |
| tsan | 3 | 1797 (1774 ± 1.1e+02, 6.0 %) | 4100 (4008 ± 2.3e+02, 5.7 %) | 9.3e+04 (9.487e+04 ± 1.2e+04, 12.6 %) | 4.859e+04 (4.757e+04 ± 3.7e+03, 7.7 %) | 766 (766 ± 0, 0.0 %) | 8.713e+04 (8.797e+04 ± 7e+03, 8.0 %) | 2.517e+04 (2.541e+04 ± 7e+02, 2.7 %) |
| tsan-dom-ea-lo-st-swmr | 3 | 1872 (1861 ± 21, 1.1 %) | 4190 (4203 ± 45, 1.1 %) | 1.01e+05 (1.04e+05 ± 7.4e+03, 7.1 %) | 5.014e+04 (5e+04 ± 1.8e+03, 3.5 %) | 766 (766 ± 0, 0.0 %) | 1.014e+05 (1.032e+05 ± 9.4e+03, 9.1 %) | 2.561e+04 (2.584e+04 ± 6.7e+02, 2.6 %) |
| tsan-dom_peeling | 3 | 1667 (1729 ± 1.1e+02, 6.5 %) | 3802 (3915 ± 2.1e+02, 5.4 %) | 1.106e+05 (1.145e+05 ± 1.6e+04, 14.0 %) | 4.583e+04 (5.003e+04 ± 8.6e+03, 17.1 %) | 766 (766 ± 0, 0.0 %) | 9.487e+04 (9.507e+04 ± 1.1e+04, 12.0 %) | 2.654e+04 (2.643e+04 ± 5.1e+02, 1.9 %) |
| tsan-dom_peeling-ea-lo-st-swmr | 3 | 1690 (1729 ± 1.2e+02, 6.9 %) | 3790 (3898 ± 2.8e+02, 7.3 %) | 1.226e+05 (1.148e+05 ± 3e+04, 26.4 %) | 4.148e+04 (4.464e+04 ± 9e+03, 20.1 %) | 766 (766 ± 0, 0.0 %) | 1.012e+05 (1.085e+05 ± 2.4e+04, 21.9 %) | 2.536e+04 (2.542e+04 ± 1.3e+02, 0.5 %) |
| tsan-dom_peeling-ea-lo-st-swmr-wp | 3 | 1696 (1750 ± 1e+02, 5.8 %) | 3872 (3978 ± 1.9e+02, 4.8 %) | 1.034e+05 (9.747e+04 ± 1.2e+04, 12.0 %) | 4.804e+04 (4.768e+04 ± 6.6e+03, 13.8 %) | 766 (766 ± 0, 0.0 %) | 9.1e+04 (9.38e+04 ± 4.9e+03, 5.2 %) | 2.578e+04 (2.603e+04 ± 4.8e+02, 1.8 %) |
| tsan-dom_peeling.STALE-0de7a7350375 | 3 | 2713 (2683 ± 65, 2.4 %) | 6218 (6144 ± 1.4e+02, 2.2 %) | 1.458e+05 (1.304e+05 ± 3.4e+04, 26.2 %) | 1.402e+05 (1.396e+05 ± 3e+03, 2.2 %) | 766 (766 ± 0, 0.0 %) | 1.091e+05 (1.158e+05 ± 1.9e+04, 16.1 %) | 2.991e+04 (2.984e+04 ± 5.1e+02, 1.7 %) |
| tsan-sound | 3 | 1683 (1736 ± 1e+02, 6.0 %) | 3841 (3921 ± 2.3e+02, 5.9 %) | 1.072e+05 (1.071e+05 ± 1.8e+04, 16.3 %) | 4.811e+04 (4.489e+04 ± 5.6e+03, 12.5 %) | 766 (766 ± 0, 0.0 %) | 8.576e+04 (9.423e+04 ± 1.8e+04, 19.4 %) | 2.518e+04 (2.521e+04 ± 3.5e+02, 1.4 %) |

##### Speedup vs stock TSan (SU) and slowdown vs native (SD), on medians; geometric mean over tests; 95 % bootstrap interval

| config | label | N | SU geomean [95 %] | SD geomean [95 %] | static sites | modes | per-test SU |
|---|---|---|---|---|---|---|---|
| orig | orig | 3 | 3.784 [3.616, 3.997] | — | 0 | pinned | walthread1:2.89, walthread2:3.55, dynamic_triggers:4.45, checkpoint_starvation_1:12.57, checkpoint_starvation_2:1.02, stress1:3.09, stress2:6.14 |
| tsan | tsan | 3 | — | 3.78 [3.62, 4.00] | 57996 | pinned |  |
| tsan-dom-ea-lo-st-swmr | AllOpt-peel | 3 | 1.051 [1.009, 1.118] | 3.60 [3.44, 3.72] | 56054 | pinned | walthread1:1.04, walthread2:1.02, dynamic_triggers:1.09, checkpoint_starvation_1:1.03, checkpoint_starvation_2:1.00, stress1:1.16, stress2:1.02 |
| tsan-dom_peeling | tsan-dom_peeling | 3 | 1.015 [0.970, 1.119] | 3.73 [3.42, 3.86] | 62996 | pinned | walthread1:0.93, walthread2:0.93, dynamic_triggers:1.19, checkpoint_starvation_1:0.94, checkpoint_starvation_2:1.00, stress1:1.09, stress2:1.05 |
| tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 3 | 1.020 [0.929, 1.144] | 3.71 [3.34, 4.06] | 61895 | pinned | walthread1:0.94, walthread2:0.92, dynamic_triggers:1.32, checkpoint_starvation_1:0.85, checkpoint_starvation_2:1.00, stress1:1.16, stress2:1.01 |
| tsan-dom_peeling-ea-lo-st-swmr-wp | AllOpt+peel (WP summaries) | 3 | 1.007 [0.950, 1.077] | 3.76 [3.56, 3.97] | 61791 | pinned | walthread1:0.94, walthread2:0.94, dynamic_triggers:1.11, checkpoint_starvation_1:0.99, checkpoint_starvation_2:1.00, stress1:1.04, stress2:1.02 |
| tsan-dom_peeling.STALE-0de7a7350375 | tsan-dom_peeling.STALE-0de7a7350375 | 3 | 1.478 [1.334, 1.576] | 2.56 [2.44, 2.82] | — | pinned | walthread1:1.51, walthread2:1.52, dynamic_triggers:1.57, checkpoint_starvation_1:2.89, checkpoint_starvation_2:1.00, stress1:1.25, stress2:1.19 |
| tsan-sound | tsan-sound | 3 | 0.998 [0.932, 1.091] | 3.79 [3.51, 4.05] | 56992 | pinned | walthread1:0.94, walthread2:0.94, dynamic_triggers:1.15, checkpoint_starvation_1:0.99, checkpoint_starvation_2:1.00, stress1:0.98, stress2:1.00 |

<!-- P5-TABLES-END -->
