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
   **Found during the first Stage B leg (2026-09-07):** at counters-off speeds the paper's memtier workload is
   too short to measure — 10 000 requests per client make an iteration ~1 s, and memtier computes per-iteration
   ops/s from 1-second progress samples, so single iterations reported 57 M ops/s on native (median 4.7 M) and
   3.5 M on `tsan-dom` (median 2.5 M). The leg is re-run with `--requests 100000` (50 M requests per iteration,
   10-25 s; `MC_REQUESTS` in `bench_one.sh`), N = 5, and the 10 000-request runs are kept as
   `memcached-10k/` for the record. Nothing else changes.
   **Thread policy corrected (2026-09-07 19:00, after the diagnostic lane checked the topology):** the pinned
   set 4-27,60-83 is 24 *physical* cores plus their SMT siblings, so deriving the thread count from `nproc`
   inside it gave `-t 48` — 48 threads on 24 cores, not 48 cores. From the SQLite leg onward the thread count
   is the physical-core count: memcached `MC_THREADS=24`, MySQL sysbench 18 (= 24*3/4); SQLite and FFmpeg take
   no thread count from the driver. The memcached leg measured before that stays as measured (every
   configuration in it ran with identical settings, and the thread-policy pilot showed the sound/stock ratio is
   insensitive to the choice: 1.008 at 48 vs 1.004 at 112); its table is labelled with its thread count and the
   two settings are never mixed inside one table.
2. **memcached** runs N = 10 (a run is ~100 s) at the paper-derived setting, unchanged client/server sharing,
   so the workload stays the paper's and the ±10 % run-to-run spread is averaged rather than redesigned.
3. **FFmpeg** keeps the paper's four codecs in the run; the headline geometric mean **excludes**
   `copy_passthrough` (0.9 s, ~13 % spread on its own) and the table shows the four-codec mean beside it.
4. **STC lever.** Both: whole-program-summaries rows (`tsan-sound-wp`, AllOpt+peel WP) and, where the
   compiler lane supplies a safe name list, `-tsan-thread-free-names` rows; the plain sound rows use neither.
5. **Yield copy** `tsan-yield-fdf7a4dd41e9` (or its rebase onto stage-b2, yield/all-b2 = 4faa12e19fb8, if the
   compiler lane designates it — those rows are rebuilt first) is in scope: the main rows (tsan, sound, AllOpt±peel, DynSTC) on
   all five applications at N = 5, compared with the stage-b copy; per-switch A/B only where a total moves.
6. **Memory caps** (machine rule after the 5-6 Sep outage; `user.slice` has a shared MemoryHigh of 110 GiB for
   every account, no swap): every build runs in a `systemd-run --user --scope -p MemoryMax=` scope (MySQL 48G,
   FFmpeg 24G, others 8G; MySQL launched alone) and every measurement in a 32G scope — sized from observed peaks
   (≤ 1.8 GB timed tree, 6.6 GB per Chromium renderer), binding below the shared limit, never `bench`.
7. Other Stage A settings stand: 48 pinned CPUs, one benchmark at a time, run-major, disturbance judged on
   the outside CPUs (threshold 0.25), provenance gate on every binary, N = 5 elsewhere, MySQL sysbench 180 s.

### Stage B, memcached leg complete (2026-09-08, tsan-perf-d3bf9f8c39fe)

16 configurations, N = 5, 100 000 requests per client, 24 server threads (physical cores), run-major, one
measurement at a time under the machine job lock; powersave-variable clock (no bench reservation, per Alexey's
standing instruction), recorded per run. Native is **2.935x** stock TSan [2.674, 3.328].

Every instrumented configuration sits within ~4 % of stock TSan and every interval straddles 1.0: DE 1.038,
AllOpt-peel 1.036, STC 1.030, SWMR 1.029, sound+names 1.029, AllOpt+peel WP 1.015, sound WP 1.016, DynSTC 1.011,
AllOpt+peel 1.009, sound 1.004, sound+names WP 0.997, DE+peel 0.998, LO 0.994, EA 0.993. With per-configuration
CV ~3 % at N = 5 the interval on a ratio is about ±2.5 %, comparable to the effects themselves — the reason a
fixed clock (bench reservation) would be needed to separate them, and the reason none of these differences is
claimed as real.

<!-- P5-TABLES-START -->

### Tables — stageB-d3bf9f8c39fe

Generated by `aggregate.py` from `results/stageB-d3bf9f8c39fe/`; regenerate with `python3 write_readme_results.py results/stageB-d3bf9f8c39fe`.

#### Cross-application summary

SU = speedup vs stock TSan, SD = slowdown vs native; geometric mean over the app's tests on per-test medians of N undisturbed runs; [95 % bootstrap interval]. **SU stable** is the same speedup over the subtests whose stock-TSan baseline CV is at most 5 %, the set chosen once from the baseline and applied to every configuration alike; it is empty where every subtest is inside that bound. Read SU as the headline and SU stable as what the data can resolve; the per-app file names the excluded subtests and their baseline CV.

| app | config | label | N | SU | SU stable | SD | static sites | modes |
|---|---|---|---|---|---|---|---|---|
| ffmpeg | orig | orig | 5 | 2.813 [2.723, 2.825] | — | — | 0 | pinned |
| ffmpeg | tsan | tsan | 5 | — | — | 2.81 [2.72, 2.82] | 514609 | pinned |
| ffmpeg | tsan-dom | tsan-dom | 5 | 1.004 [0.992, 1.010] | — | 2.80 [2.72, 2.82] | 490223 | pinned |
| ffmpeg | tsan-dom-ea-lo-st-swmr | AllOpt-peel | 5 | 1.001 [0.991, 1.008] | — | 2.81 [2.72, 2.82] | 474557 | pinned |
| ffmpeg | tsan-dom_peeling | tsan-dom_peeling | 5 | 1.007 [0.991, 1.011] | — | 2.79 [2.72, 2.82] | 560213 | pinned |
| ffmpeg | tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 5 | 1.004 [0.992, 1.011] | — | 2.80 [2.72, 2.82] | 542684 | pinned |
| ffmpeg | tsan-ea | tsan-ea | 5 | 1.002 [0.991, 1.009] | — | 2.81 [2.72, 2.82] | 497410 | pinned |
| ffmpeg | tsan-lo | tsan-lo | 5 | 0.993 [0.983, 1.006] | — | 2.83 [2.74, 2.84] | 514609 | pinned |
| ffmpeg | tsan-sound | tsan-sound | 5 | 0.999 [0.989, 1.008] | — | 2.82 [2.73, 2.83] | 497410 | pinned |
| ffmpeg | tsan-st | tsan-st | 5 | 0.996 [0.986, 1.004] | — | 2.82 [2.74, 2.84] | 514609 | pinned |
| ffmpeg | tsan-stmt | tsan-stmt | 5 | 1.113 [1.097, 1.124] | — | 2.53 [2.45, 2.55] | 514493 | pinned |
| ffmpeg | tsan-swmr | tsan-swmr | 5 | 0.994 [0.985, 1.007] | — | 2.83 [2.73, 2.84] | 514609 | pinned |
| memcached | orig | orig | 5 | 2.828 [2.674, 3.021] | — | — | 0 | pinned |
| memcached | tsan | tsan | 5 | — | — | 2.83 [2.67, 3.02] | 6748 | pinned |
| memcached | tsan-dom | tsan-dom | 5 | 1.000 [0.919, 1.056] | — | 2.83 [2.66, 3.12] | 6508 | pinned |
| memcached | tsan-dom-ea-lo-st-swmr | AllOpt-peel | 5 | 0.998 [0.918, 1.047] | — | 2.83 [2.69, 3.13] | 6408 | pinned |
| memcached | tsan-dom_peeling | tsan-dom_peeling | 5 | 0.961 [0.936, 1.030] | — | 2.94 [2.73, 3.07] | 7270 | pinned |
| memcached | tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 5 | 0.972 [0.946, 1.042] | — | 2.91 [2.70, 3.04] | 7130 | pinned |
| memcached | tsan-dom_peeling-ea-lo-st-swmr-wp | AllOpt+peel (WP summaries) | 5 | 0.986 [0.925, 1.080] | — | 2.87 [2.60, 3.10] | 6699 | pinned |
| memcached | tsan-ea | tsan-ea | 5 | 0.957 [0.934, 1.060] | — | 2.96 [2.65, 3.08] | 6653 | pinned |
| memcached | tsan-lo | tsan-lo | 5 | 0.967 [0.948, 1.073] | — | 2.92 [2.62, 3.03] | 6739 | pinned |
| memcached | tsan-sound | tsan-sound | 5 | 0.968 [0.943, 1.020] | — | 2.92 [2.76, 3.05] | 6643 | pinned |
| memcached | tsan-sound-tfn | tsan-sound-tfn | 5 | 0.972 [0.947, 1.054] | — | 2.91 [2.67, 3.03] | 6590 | pinned |
| memcached | tsan-sound-tfn-wp | tsan-sound-tfn-wp | 5 | 0.960 [0.944, 1.063] | — | 2.94 [2.64, 3.04] | 6227 | pinned |
| memcached | tsan-sound-wp | sound (WP summaries) | 5 | 0.969 [0.946, 1.061] | — | 2.92 [2.65, 3.04] | 6280 | pinned |
| memcached | tsan-st | tsan-st | 5 | 0.992 [0.939, 1.091] | — | 2.85 [2.58, 3.06] | 6747 | pinned |
| memcached | tsan-stmt | tsan-stmt | 5 | 0.974 [0.929, 1.068] | — | 2.90 [2.63, 3.09] | 6810 | pinned |
| memcached | tsan-swmr | tsan-swmr | 5 | 0.993 [0.980, 1.054] | — | 2.85 [2.67, 2.93] | 6748 | pinned |
| mysql | orig | orig | 5 | 10.836 [9.867, 11.728] | — | — | 0 | pinned |
| mysql | tsan | tsan | 5 | — | — | 10.84 [9.87, 11.73] | 602434 | pinned |
| mysql | tsan-dom | tsan-dom | 5 | 1.009 [0.933, 1.069] | — | 10.74 [9.95, 11.65] | 578658 | pinned |
| mysql | tsan-dom-ea-lo-st-swmr | AllOpt-peel | 5 | 1.022 [0.938, 1.082] | — | 10.61 [9.83, 11.55] | 574085 | pinned |
| mysql | tsan-dom_peeling | tsan-dom_peeling | 5 | 0.999 [0.923, 1.065] | — | 10.85 [9.98, 11.74] | 645512 | pinned |
| mysql | tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 5 | 1.012 [0.954, 1.096] | — | 10.71 [9.67, 11.36] | 640355 | pinned |
| mysql | tsan-ea | tsan-ea | 5 | 1.034 [0.959, 1.080] | — | 10.48 [9.78, 11.35] | 597140 | pinned |
| mysql | tsan-lo | tsan-lo | 5 | 0.986 [0.903, 1.040] | — | 10.99 [10.23, 12.05] | 602434 | pinned |
| mysql | tsan-sound | tsan-sound | 5 | 1.021 [0.938, 1.078] | — | 10.62 [9.82, 11.55] | 597140 | pinned |
| mysql | tsan-st | tsan-st | 5 | 0.983 [0.896, 1.056] | — | 11.02 [10.05, 12.11] | 602434 | pinned |
| mysql | tsan-stmt | tsan-stmt | 5 | 0.983 [0.912, 1.053] | — | 11.02 [10.09, 11.90] | 602809 | pinned |
| mysql | tsan-swmr | tsan-swmr | 5 | 1.006 [0.917, 1.073] | — | 10.78 [9.90, 11.83] | 602434 | pinned |
| redis | orig | orig | 5 | 7.934 [7.747, 8.148] | 7.896 [7.708, 8.108] | — | 0 | pinned |
| redis | tsan | tsan | 5 | — | — | 7.93 [7.75, 8.15] | 37941 | pinned |
| redis | tsan-dom | tsan-dom | 5 | 1.020 [1.002, 1.045] | 1.016 [1.001, 1.043] | 7.78 [7.59, 7.93] | 37396 | pinned |
| redis | tsan-dom-ea-lo-st-swmr | AllOpt-peel | 5 | 1.010 [0.991, 1.033] | 1.007 [0.988, 1.030] | 7.85 [7.68, 8.04] | 37077 | pinned |
| redis | tsan-dom_peeling | tsan-dom_peeling | 5 | 1.017 [0.989, 1.035] | 1.014 [0.989, 1.034] | 7.80 [7.67, 8.03] | 43668 | pinned |
| redis | tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 5 | 1.008 [0.994, 1.038] | 1.009 [0.994, 1.039] | 7.87 [7.64, 8.00] | 43292 | pinned |
| redis | tsan-dom_peeling-ea-lo-st-swmr-wp | AllOpt+peel (WP summaries) | 5 | 1.027 [1.008, 1.051] | 1.022 [1.007, 1.049] | 7.72 [7.55, 7.88] | 40692 | pinned |
| redis | tsan-ea | tsan-ea | 5 | 1.012 [0.988, 1.029] | 1.007 [0.988, 1.028] | 7.84 [7.71, 8.05] | 37608 | pinned |
| redis | tsan-lo | tsan-lo | 5 | 1.010 [0.989, 1.034] | 1.006 [0.988, 1.033] | 7.86 [7.67, 8.04] | 37941 | pinned |
| redis | tsan-sound | tsan-sound | 5 | 1.003 [0.984, 1.027] | 0.998 [0.982, 1.024] | 7.91 [7.73, 8.08] | 37608 | pinned |
| redis | tsan-sound-wp | sound (WP summaries) | 5 | 1.017 [0.994, 1.038] | 1.011 [0.990, 1.035] | 7.80 [7.64, 8.01] | 35372 | pinned |
| redis | tsan-st | tsan-st | 5 | 1.017 [0.991, 1.037] | 1.014 [0.990, 1.036] | 7.80 [7.65, 8.03] | 37941 | pinned |
| redis | tsan-stmt | tsan-stmt | 5 | 0.969 [0.950, 0.990] | 0.970 [0.951, 0.990] | 8.19 [7.99, 8.37] | 37882 | pinned |
| redis | tsan-swmr | tsan-swmr | 5 | 1.008 [0.993, 1.035] | 1.004 [0.990, 1.033] | 7.87 [7.67, 8.01] | 37941 | pinned |
| sqlite | orig | orig | 5 | 3.181 [2.937, 3.482] | 2.214 [2.136, 2.256] | — | 0 | pinned |
| sqlite | tsan | tsan | 5 | — | — | 3.18 [2.94, 3.48] | 57996 | pinned |
| sqlite | tsan-dom | tsan-dom | 5 | 0.978 [0.924, 1.126] | 1.001 [0.989, 1.012] | 3.25 [2.80, 3.49] | 57033 | pinned |
| sqlite | tsan-dom-ea-lo-st-swmr | AllOpt-peel | 5 | 1.036 [0.924, 1.110] | 1.003 [0.997, 1.012] | 3.07 [2.89, 3.47] | 56087 | pinned |
| sqlite | tsan-dom_peeling | tsan-dom_peeling | 5 | 0.978 [0.920, 1.050] | 1.000 [0.992, 1.010] | 3.25 [3.03, 3.51] | 62996 | pinned |
| sqlite | tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 5 | 0.999 [0.921, 1.098] | 1.002 [0.994, 1.013] | 3.18 [2.93, 3.49] | 61931 | pinned |
| sqlite | tsan-dom_peeling-ea-lo-st-swmr-wp | AllOpt+peel (WP summaries) | 5 | 0.993 [0.923, 1.074] | 1.002 [0.969, 1.014] | 3.20 [2.98, 3.50] | 61827 | pinned |
| sqlite | tsan-ea | tsan-ea | 5 | 0.997 [0.948, 1.110] | 1.002 [0.993, 1.011] | 3.19 [2.88, 3.43] | 57025 | pinned |
| sqlite | tsan-lo | tsan-lo | 5 | 0.964 [0.899, 1.077] | 0.995 [0.988, 1.007] | 3.30 [2.97, 3.58] | 57996 | pinned |
| sqlite | tsan-sound | tsan-sound | 5 | 0.991 [0.921, 1.062] | 1.003 [0.996, 1.013] | 3.21 [2.98, 3.49] | 57025 | pinned |
| sqlite | tsan-sound-wp | sound (WP summaries) | 5 | 1.024 [0.941, 1.120] | 0.997 [0.983, 1.008] | 3.11 [2.85, 3.43] | 56890 | pinned |
| sqlite | tsan-st | tsan-st | 5 | 1.000 [0.920, 1.093] | 0.999 [0.988, 1.010] | 3.18 [2.93, 3.48] | 57996 | pinned |
| sqlite | tsan-stmt | tsan-stmt | 5 | 0.988 [0.942, 1.130] | 0.983 [0.978, 0.995] | 3.22 [2.85, 3.44] | 57957 | pinned |
| sqlite | tsan-swmr | tsan-swmr | 5 | 0.994 [0.930, 1.118] | 1.003 [0.996, 1.013] | 3.20 [2.83, 3.46] | 57996 | pinned |

#### ffmpeg

Session: mode=pinned cpuset=4-27,60-83 governor=powersave no_turbo=0 host=focs-server started=2026-09-08T08:56:45

| config | N | h264_libx264 median (mean ± σ, CV) | copy_passthrough median (mean ± σ, CV) | mjpeg median (mean ± σ, CV) | h265_libx265 median (mean ± σ, CV) |
|---|---|---|---|---|---|
| orig | 5 | 34.45 (34.5 ± 0.15, 0.4 %) | 0.12 (0.124 ± 0.0055, 4.4 %) | 3.53 (3.556 ± 0.057, 1.6 %) | 39.06 (39.1 ± 0.08, 0.2 %) |
| tsan | 5 | 42.49 (42.58 ± 0.23, 0.6 %) | 0.69 (0.684 ± 0.0089, 1.3 %) | 23.53 (23.53 ± 0.2, 0.9 %) | 51.71 (51.71 ± 0.1, 0.2 %) |
| tsan-dom | 5 | 42.45 (42.52 ± 0.15, 0.4 %) | 0.69 (0.69 ± 0.0071, 1.0 %) | 23.22 (23.26 ± 0.17, 0.7 %) | 51.71 (51.67 ± 0.098, 0.2 %) |
| tsan-dom-ea-lo-st-swmr | 5 | 42.36 (42.4 ± 0.21, 0.5 %) | 0.7 (0.696 ± 0.0055, 0.8 %) | 23.24 (23.23 ± 0.038, 0.2 %) | 51.63 (51.64 ± 0.14, 0.3 %) |
| tsan-dom_peeling | 5 | 42.41 (42.5 ± 0.25, 0.6 %) | 0.68 (0.686 ± 0.0089, 1.3 %) | 23.27 (23.35 ± 0.25, 1.1 %) | 51.67 (51.67 ± 0.061, 0.1 %) |
| tsan-dom_peeling-ea-lo-st-swmr | 5 | 42.37 (42.46 ± 0.22, 0.5 %) | 0.69 (0.69 ± 0.0071, 1.0 %) | 23.2 (23.26 ± 0.16, 0.7 %) | 51.68 (51.64 ± 0.13, 0.3 %) |
| tsan-ea | 5 | 42.47 (42.42 ± 0.097, 0.2 %) | 0.68 (0.682 ± 0.0045, 0.7 %) | 23.69 (23.68 ± 0.22, 0.9 %) | 51.63 (51.62 ± 0.12, 0.2 %) |
| tsan-lo | 5 | 42.44 (42.49 ± 0.16, 0.4 %) | 0.71 (0.702 ± 0.013, 1.9 %) | 23.57 (23.62 ± 0.14, 0.6 %) | 51.66 (51.71 ± 0.091, 0.2 %) |
| tsan-sound | 5 | 42.37 (42.49 ± 0.23, 0.5 %) | 0.69 (0.688 ± 0.0045, 0.7 %) | 23.75 (23.61 ± 0.28, 1.2 %) | 51.59 (51.59 ± 0.08, 0.2 %) |
| tsan-st | 5 | 42.47 (42.52 ± 0.13, 0.3 %) | 0.7 (0.7 ± 0.0071, 1.0 %) | 23.52 (23.45 ± 0.12, 0.5 %) | 51.74 (51.73 ± 0.11, 0.2 %) |
| tsan-stmt | 5 | 42.45 (42.49 ± 0.21, 0.5 %) | 0.44 (0.438 ± 0.0084, 1.9 %) | 24.02 (24.11 ± 0.3, 1.2 %) | 51.75 (51.75 ± 0.019, 0.0 %) |
| tsan-swmr | 5 | 42.5 (42.52 ± 0.18, 0.4 %) | 0.7 (0.692 ± 0.011, 1.6 %) | 23.68 (23.67 ± 0.2, 0.8 %) | 51.83 (51.78 ± 0.2, 0.4 %) |

##### Speedup vs stock TSan (SU) and slowdown vs native (SD), on medians; geometric mean over tests; 95 % bootstrap interval

| config | label | N | SU geomean [95 %] | SU stable [95 %] | SD geomean [95 %] | static sites | modes | per-test SU |
|---|---|---|---|---|---|---|---|---|
| orig | orig | 5 | 2.813 [2.723, 2.825] | — | — | 0 | pinned | h264_libx264:1.23, copy_passthrough:5.75, mjpeg:6.67, h265_libx265:1.32 |
| tsan | tsan | 5 | — | — | 2.81 [2.72, 2.82] | 514609 | pinned |  |
| tsan-dom | tsan-dom | 5 | 1.004 [0.992, 1.010] | — | 2.80 [2.72, 2.82] | 490223 | pinned | h264_libx264:1.00, copy_passthrough:1.00, mjpeg:1.01, h265_libx265:1.00 |
| tsan-dom-ea-lo-st-swmr | AllOpt-peel | 5 | 1.001 [0.991, 1.008] | — | 2.81 [2.72, 2.82] | 474557 | pinned | h264_libx264:1.00, copy_passthrough:0.99, mjpeg:1.01, h265_libx265:1.00 |
| tsan-dom_peeling | tsan-dom_peeling | 5 | 1.007 [0.991, 1.011] | — | 2.79 [2.72, 2.82] | 560213 | pinned | h264_libx264:1.00, copy_passthrough:1.01, mjpeg:1.01, h265_libx265:1.00 |
| tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 5 | 1.004 [0.992, 1.011] | — | 2.80 [2.72, 2.82] | 542684 | pinned | h264_libx264:1.00, copy_passthrough:1.00, mjpeg:1.01, h265_libx265:1.00 |
| tsan-ea | tsan-ea | 5 | 1.002 [0.991, 1.009] | — | 2.81 [2.72, 2.82] | 497410 | pinned | h264_libx264:1.00, copy_passthrough:1.01, mjpeg:0.99, h265_libx265:1.00 |
| tsan-lo | tsan-lo | 5 | 0.993 [0.983, 1.006] | — | 2.83 [2.74, 2.84] | 514609 | pinned | h264_libx264:1.00, copy_passthrough:0.97, mjpeg:1.00, h265_libx265:1.00 |
| tsan-sound | tsan-sound | 5 | 0.999 [0.989, 1.008] | — | 2.82 [2.73, 2.83] | 497410 | pinned | h264_libx264:1.00, copy_passthrough:1.00, mjpeg:0.99, h265_libx265:1.00 |
| tsan-st | tsan-st | 5 | 0.996 [0.986, 1.004] | — | 2.82 [2.74, 2.84] | 514609 | pinned | h264_libx264:1.00, copy_passthrough:0.99, mjpeg:1.00, h265_libx265:1.00 |
| tsan-stmt | tsan-stmt | 5 | 1.113 [1.097, 1.124] | — | 2.53 [2.45, 2.55] | 514493 | pinned | h264_libx264:1.00, copy_passthrough:1.57, mjpeg:0.98, h265_libx265:1.00 |
| tsan-swmr | tsan-swmr | 5 | 0.994 [0.985, 1.007] | — | 2.83 [2.73, 2.84] | 514609 | pinned | h264_libx264:1.00, copy_passthrough:0.99, mjpeg:0.99, h265_libx265:1.00 |

#### memcached

Session: mode=pinned cpuset=4-27,60-83 governor=powersave no_turbo=0 host=focs-server started=2026-09-09T04:34:23

| config | N | ops_sec median (mean ± σ, CV) |
|---|---|---|
| orig | 5 | 4.7e+06 (4.683e+06 ± 1.3e+05, 2.8 %) |
| tsan | 5 | 1.662e+06 (1.641e+06 ± 4e+04, 2.4 %) |
| tsan-dom | 5 | 1.662e+06 (1.626e+06 ± 6.8e+04, 4.2 %) |
| tsan-dom-ea-lo-st-swmr | 5 | 1.66e+06 (1.637e+06 ± 5.6e+04, 3.4 %) |
| tsan-dom_peeling | 5 | 1.598e+06 (1.601e+06 ± 2.8e+04, 1.8 %) |
| tsan-dom_peeling-ea-lo-st-swmr | 5 | 1.616e+06 (1.62e+06 ± 3.1e+04, 1.9 %) |
| tsan-dom_peeling-ea-lo-st-swmr-wp | 5 | 1.638e+06 (1.635e+06 ± 6e+04, 3.7 %) |
| tsan-ea | 5 | 1.59e+06 (1.615e+06 ± 5.4e+04, 3.3 %) |
| tsan-lo | 5 | 1.607e+06 (1.626e+06 ± 5e+04, 3.1 %) |
| tsan-sound | 5 | 1.608e+06 (1.603e+06 ± 2.1e+04, 1.3 %) |
| tsan-sound-tfn | 5 | 1.617e+06 (1.633e+06 ± 4.3e+04, 2.6 %) |
| tsan-sound-tfn-wp | 5 | 1.596e+06 (1.614e+06 ± 4.5e+04, 2.8 %) |
| tsan-sound-wp | 5 | 1.611e+06 (1.627e+06 ± 4.1e+04, 2.5 %) |
| tsan-st | 5 | 1.649e+06 (1.65e+06 ± 5.9e+04, 3.6 %) |
| tsan-stmt | 5 | 1.619e+06 (1.63e+06 ± 5.8e+04, 3.5 %) |
| tsan-swmr | 5 | 1.65e+06 (1.657e+06 ± 1.5e+04, 0.9 %) |

##### Speedup vs stock TSan (SU) and slowdown vs native (SD), on medians; geometric mean over tests; 95 % bootstrap interval

| config | label | N | SU geomean [95 %] | SU stable [95 %] | SD geomean [95 %] | static sites | modes | per-test SU |
|---|---|---|---|---|---|---|---|---|
| orig | orig | 5 | 2.828 [2.674, 3.021] | — | — | 0 | pinned | ops_sec:2.83 |
| tsan | tsan | 5 | — | — | 2.83 [2.67, 3.02] | 6748 | pinned |  |
| tsan-dom | tsan-dom | 5 | 1.000 [0.919, 1.056] | — | 2.83 [2.66, 3.12] | 6508 | pinned | ops_sec:1.00 |
| tsan-dom-ea-lo-st-swmr | AllOpt-peel | 5 | 0.998 [0.918, 1.047] | — | 2.83 [2.69, 3.13] | 6408 | pinned | ops_sec:1.00 |
| tsan-dom_peeling | tsan-dom_peeling | 5 | 0.961 [0.936, 1.030] | — | 2.94 [2.73, 3.07] | 7270 | pinned | ops_sec:0.96 |
| tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 5 | 0.972 [0.946, 1.042] | — | 2.91 [2.70, 3.04] | 7130 | pinned | ops_sec:0.97 |
| tsan-dom_peeling-ea-lo-st-swmr-wp | AllOpt+peel (WP summaries) | 5 | 0.986 [0.925, 1.080] | — | 2.87 [2.60, 3.10] | 6699 | pinned | ops_sec:0.99 |
| tsan-ea | tsan-ea | 5 | 0.957 [0.934, 1.060] | — | 2.96 [2.65, 3.08] | 6653 | pinned | ops_sec:0.96 |
| tsan-lo | tsan-lo | 5 | 0.967 [0.948, 1.073] | — | 2.92 [2.62, 3.03] | 6739 | pinned | ops_sec:0.97 |
| tsan-sound | tsan-sound | 5 | 0.968 [0.943, 1.020] | — | 2.92 [2.76, 3.05] | 6643 | pinned | ops_sec:0.97 |
| tsan-sound-tfn | tsan-sound-tfn | 5 | 0.972 [0.947, 1.054] | — | 2.91 [2.67, 3.03] | 6590 | pinned | ops_sec:0.97 |
| tsan-sound-tfn-wp | tsan-sound-tfn-wp | 5 | 0.960 [0.944, 1.063] | — | 2.94 [2.64, 3.04] | 6227 | pinned | ops_sec:0.96 |
| tsan-sound-wp | sound (WP summaries) | 5 | 0.969 [0.946, 1.061] | — | 2.92 [2.65, 3.04] | 6280 | pinned | ops_sec:0.97 |
| tsan-st | tsan-st | 5 | 0.992 [0.939, 1.091] | — | 2.85 [2.58, 3.06] | 6747 | pinned | ops_sec:0.99 |
| tsan-stmt | tsan-stmt | 5 | 0.974 [0.929, 1.068] | — | 2.90 [2.63, 3.09] | 6810 | pinned | ops_sec:0.97 |
| tsan-swmr | tsan-swmr | 5 | 0.993 [0.980, 1.054] | — | 2.85 [2.67, 2.93] | 6748 | pinned | ops_sec:0.99 |

#### mysql

Session: mode=pinned cpuset=4-27,60-83 governor=powersave no_turbo=0 host=focs-server started=2026-09-09T04:54:40

| config | N | oltp_read_only median (mean ± σ, CV) | oltp_read_write median (mean ± σ, CV) | oltp_write_only median (mean ± σ, CV) | select_random_points median (mean ± σ, CV) | select_random_ranges median (mean ± σ, CV) |
|---|---|---|---|---|---|---|
| orig | 5 | 1.574e+06 (1.614e+06 ± 1.2e+05, 7.5 %) | 1.555e+06 (1.562e+06 ± 1.8e+05, 11.2 %) | 1.591e+06 (1.577e+06 ± 1.2e+05, 7.6 %) | 5.245e+05 (5.208e+05 ± 2.4e+04, 4.6 %) | 1.001e+06 (1.006e+06 ± 1.1e+05, 10.7 %) |
| tsan | 5 | 1.228e+05 (1.261e+05 ± 1.2e+04, 9.4 %) | 1.232e+05 (1.261e+05 ± 1.2e+04, 9.3 %) | 1.433e+05 (1.436e+05 ± 5.1e+03, 3.6 %) | 6.03e+04 (5.945e+04 ± 3.5e+03, 6.0 %) | 1.047e+05 (1.048e+05 ± 4.1e+03, 3.9 %) |
| tsan-dom | 5 | 1.233e+05 (1.229e+05 ± 1.1e+04, 8.8 %) | 1.242e+05 (1.274e+05 ± 6e+03, 4.7 %) | 1.473e+05 (1.461e+05 ± 3.2e+03, 2.2 %) | 5.887e+04 (5.766e+04 ± 3.1e+03, 5.3 %) | 1.076e+05 (1.077e+05 ± 2.9e+03, 2.7 %) |
| tsan-dom-ea-lo-st-swmr | 5 | 1.336e+05 (1.318e+05 ± 1e+04, 7.8 %) | 1.266e+05 (1.263e+05 ± 6.3e+03, 5.0 %) | 1.458e+05 (1.453e+05 ± 5.1e+03, 3.5 %) | 5.862e+04 (5.769e+04 ± 2.7e+03, 4.6 %) | 1.054e+05 (1.064e+05 ± 8.2e+03, 7.7 %) |
| tsan-dom_peeling | 5 | 1.233e+05 (1.265e+05 ± 9.7e+03, 7.7 %) | 1.254e+05 (1.274e+05 ± 6.1e+03, 4.8 %) | 1.439e+05 (1.437e+05 ± 3.8e+03, 2.6 %) | 5.637e+04 (5.585e+04 ± 3.3e+03, 6.0 %) | 1.086e+05 (1.068e+05 ± 6.1e+03, 5.8 %) |
| tsan-dom_peeling-ea-lo-st-swmr | 5 | 1.241e+05 (1.292e+05 ± 1.2e+04, 9.1 %) | 1.231e+05 (1.286e+05 ± 8.6e+03, 6.7 %) | 1.468e+05 (1.481e+05 ± 3.9e+03, 2.7 %) | 6.014e+04 (5.998e+04 ± 1.6e+03, 2.6 %) | 1.079e+05 (1.082e+05 ± 5.9e+03, 5.4 %) |
| tsan-ea | 5 | 1.351e+05 (1.328e+05 ± 5.4e+03, 4.0 %) | 1.333e+05 (1.302e+05 ± 7.1e+03, 5.5 %) | 1.456e+05 (1.45e+05 ± 2e+03, 1.4 %) | 5.674e+04 (5.735e+04 ± 1.9e+03, 3.4 %) | 1.089e+05 (1.088e+05 ± 3.5e+03, 3.2 %) |
| tsan-lo | 5 | 1.236e+05 (1.225e+05 ± 1.2e+04, 9.5 %) | 1.247e+05 (1.233e+05 ± 6.6e+03, 5.4 %) | 1.429e+05 (1.389e+05 ± 7.8e+03, 5.6 %) | 5.546e+04 (5.63e+04 ± 1.6e+03, 2.8 %) | 1.042e+05 (1.034e+05 ± 5.1e+03, 4.9 %) |
| tsan-sound | 5 | 1.301e+05 (1.322e+05 ± 9.4e+03, 7.1 %) | 1.311e+05 (1.291e+05 ± 5.4e+03, 4.2 %) | 1.465e+05 (1.448e+05 ± 7.1e+03, 4.9 %) | 5.575e+04 (5.595e+04 ± 2.1e+03, 3.8 %) | 1.089e+05 (1.073e+05 ± 8.4e+03, 7.8 %) |
| tsan-st | 5 | 1.201e+05 (1.246e+05 ± 1.3e+04, 10.7 %) | 1.254e+05 (1.275e+05 ± 6.9e+03, 5.4 %) | 1.405e+05 (1.422e+05 ± 5.6e+03, 4.0 %) | 5.554e+04 (5.302e+04 ± 6.9e+03, 13.1 %) | 1.068e+05 (1.05e+05 ± 3.9e+03, 3.7 %) |
| tsan-stmt | 5 | 1.204e+05 (1.222e+05 ± 9.4e+03, 7.7 %) | 1.218e+05 (1.243e+05 ± 1e+04, 8.4 %) | 1.449e+05 (1.429e+05 ± 4.6e+03, 3.2 %) | 5.725e+04 (5.646e+04 ± 2.4e+03, 4.3 %) | 1.034e+05 (1.055e+05 ± 5.8e+03, 5.5 %) |
| tsan-swmr | 5 | 1.363e+05 (1.322e+05 ± 1.2e+04, 8.9 %) | 1.199e+05 (1.239e+05 ± 1.3e+04, 10.7 %) | 1.453e+05 (1.441e+05 ± 4.4e+03, 3.1 %) | 5.64e+04 (5.704e+04 ± 2.3e+03, 4.0 %) | 1.052e+05 (1.031e+05 ± 8e+03, 7.7 %) |

##### Speedup vs stock TSan (SU) and slowdown vs native (SD), on medians; geometric mean over tests; 95 % bootstrap interval

| config | label | N | SU geomean [95 %] | SU stable [95 %] | SD geomean [95 %] | static sites | modes | per-test SU |
|---|---|---|---|---|---|---|---|---|
| orig | orig | 5 | 10.836 [9.867, 11.728] | — | — | 0 | pinned | oltp_read_only:12.82, oltp_read_write:12.63, oltp_write_only:11.11, select_random_points:8.70, select_random_ranges:9.56 |
| tsan | tsan | 5 | — | — | 10.84 [9.87, 11.73] | 602434 | pinned |  |
| tsan-dom | tsan-dom | 5 | 1.009 [0.933, 1.069] | — | 10.74 [9.95, 11.65] | 578658 | pinned | oltp_read_only:1.00, oltp_read_write:1.01, oltp_write_only:1.03, select_random_points:0.98, select_random_ranges:1.03 |
| tsan-dom-ea-lo-st-swmr | AllOpt-peel | 5 | 1.022 [0.938, 1.082] | — | 10.61 [9.83, 11.55] | 574085 | pinned | oltp_read_only:1.09, oltp_read_write:1.03, oltp_write_only:1.02, select_random_points:0.97, select_random_ranges:1.01 |
| tsan-dom_peeling | tsan-dom_peeling | 5 | 0.999 [0.923, 1.065] | — | 10.85 [9.98, 11.74] | 645512 | pinned | oltp_read_only:1.00, oltp_read_write:1.02, oltp_write_only:1.00, select_random_points:0.93, select_random_ranges:1.04 |
| tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 5 | 1.012 [0.954, 1.096] | — | 10.71 [9.67, 11.36] | 640355 | pinned | oltp_read_only:1.01, oltp_read_write:1.00, oltp_write_only:1.02, select_random_points:1.00, select_random_ranges:1.03 |
| tsan-ea | tsan-ea | 5 | 1.034 [0.959, 1.080] | — | 10.48 [9.78, 11.35] | 597140 | pinned | oltp_read_only:1.10, oltp_read_write:1.08, oltp_write_only:1.02, select_random_points:0.94, select_random_ranges:1.04 |
| tsan-lo | tsan-lo | 5 | 0.986 [0.903, 1.040] | — | 10.99 [10.23, 12.05] | 602434 | pinned | oltp_read_only:1.01, oltp_read_write:1.01, oltp_write_only:1.00, select_random_points:0.92, select_random_ranges:1.00 |
| tsan-sound | tsan-sound | 5 | 1.021 [0.938, 1.078] | — | 10.62 [9.82, 11.55] | 597140 | pinned | oltp_read_only:1.06, oltp_read_write:1.06, oltp_write_only:1.02, select_random_points:0.92, select_random_ranges:1.04 |
| tsan-st | tsan-st | 5 | 0.983 [0.896, 1.056] | — | 11.02 [10.05, 12.11] | 602434 | pinned | oltp_read_only:0.98, oltp_read_write:1.02, oltp_write_only:0.98, select_random_points:0.92, select_random_ranges:1.02 |
| tsan-stmt | tsan-stmt | 5 | 0.983 [0.912, 1.053] | — | 11.02 [10.09, 11.90] | 602809 | pinned | oltp_read_only:0.98, oltp_read_write:0.99, oltp_write_only:1.01, select_random_points:0.95, select_random_ranges:0.99 |
| tsan-swmr | tsan-swmr | 5 | 1.006 [0.917, 1.073] | — | 10.78 [9.90, 11.83] | 602434 | pinned | oltp_read_only:1.11, oltp_read_write:0.97, oltp_write_only:1.01, select_random_points:0.94, select_random_ranges:1.00 |

#### redis

Session: mode=pinned cpuset=4-27,60-83 governor=powersave no_turbo=0 host=focs-server started=2026-09-08T07:28:38

| config | N | PING_INLINE median (mean ± σ, CV) | PING_MBULK median (mean ± σ, CV) | SET median (mean ± σ, CV) | GET median (mean ± σ, CV) | INCR median (mean ± σ, CV) | RPUSH median (mean ± σ, CV) | LPOP median (mean ± σ, CV) | RPOP median (mean ± σ, CV) | SADD median (mean ± σ, CV) | HSET median (mean ± σ, CV) | SPOP median (mean ± σ, CV) | ZADD median (mean ± σ, CV) | ZPOPMIN median (mean ± σ, CV) | LPUSH median (mean ± σ, CV) | LRANGE_100 median (mean ± σ, CV) | LRANGE_300 median (mean ± σ, CV) | LRANGE_500 median (mean ± σ, CV) | LRANGE_600 median (mean ± σ, CV) | MSET median (mean ± σ, CV) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| orig | 5 | 4.407e+06 (4.444e+06 ± 3.2e+05, 7.2 %) | 6.625e+06 (6.742e+06 ± 2.8e+05, 4.2 %) | 3.346e+06 (3.269e+06 ± 2.1e+05, 6.6 %) | 3.985e+06 (3.967e+06 ± 5.4e+04, 1.4 %) | 4.275e+06 (4.316e+06 ± 2.9e+05, 6.7 %) | 3.146e+06 (3.11e+06 ± 1.3e+05, 4.3 %) | 2.891e+06 (2.859e+06 ± 9.3e+04, 3.3 %) | 4.675e+06 (4.784e+06 ± 3.1e+05, 6.5 %) | 3.585e+06 (3.561e+06 ± 1.7e+05, 4.8 %) | 2.802e+06 (2.787e+06 ± 3.5e+04, 1.3 %) | 5.408e+06 (5.4e+06 ± 1.7e+05, 3.1 %) | 2.647e+06 (2.618e+06 ± 6.4e+04, 2.4 %) | 5.266e+06 (5.383e+06 ± 1.8e+05, 3.3 %) | 2.834e+06 (2.841e+06 ± 4.7e+04, 1.6 %) | 1.52e+05 (1.521e+05 ± 2.9e+03, 1.9 %) | 4.277e+04 (4.235e+04 ± 1.4e+03, 3.3 %) | 2.526e+04 (2.523e+04 ± 6.2e+02, 2.5 %) | 2.067e+04 (2.069e+04 ± 5.5e+02, 2.6 %) | 5.38e+05 (5.381e+05 ± 4.4e+04, 8.2 %) |
| tsan | 5 | 5.458e+05 (5.44e+05 ± 6.8e+03, 1.3 %) | 7.655e+05 (7.866e+05 ± 5.1e+04, 6.4 %) | 3.63e+05 (3.624e+05 ± 1.2e+04, 3.2 %) | 4.679e+05 (4.627e+05 ± 2.5e+04, 5.5 %) | 4.662e+05 (4.59e+05 ± 2.1e+04, 4.5 %) | 2.898e+05 (2.874e+05 ± 9.4e+03, 3.3 %) | 2.57e+05 (2.56e+05 ± 6.5e+03, 2.6 %) | 5.186e+05 (5.18e+05 ± 2.7e+04, 5.2 %) | 4.067e+05 (3.991e+05 ± 2.1e+04, 5.2 %) | 3.159e+05 (3.114e+05 ± 2e+04, 6.5 %) | 5.63e+05 (5.723e+05 ± 4e+04, 7.0 %) | 3.112e+05 (3.124e+05 ± 9.5e+03, 3.0 %) | 5.592e+05 (5.713e+05 ± 3.3e+04, 5.8 %) | 2.406e+05 (2.412e+05 ± 4.4e+03, 1.8 %) | 2.921e+04 (2.865e+04 ± 1e+03, 3.5 %) | 9747 (9747 ± 74, 0.8 %) | 5962 (5961 ± 28, 0.5 %) | 5006 (4986 ± 49, 1.0 %) | 6.858e+04 (6.908e+04 ± 1.4e+03, 2.0 %) |
| tsan-dom | 5 | 5.344e+05 (5.293e+05 ± 1.9e+04, 3.6 %) | 8.365e+05 (8.117e+05 ± 4e+04, 4.9 %) | 3.659e+05 (3.68e+05 ± 6.2e+03, 1.7 %) | 4.71e+05 (4.751e+05 ± 8.5e+03, 1.8 %) | 4.71e+05 (4.722e+05 ± 6.8e+03, 1.4 %) | 2.955e+05 (2.926e+05 ± 6e+03, 2.0 %) | 2.716e+05 (2.702e+05 ± 4.2e+03, 1.6 %) | 5.371e+05 (5.393e+05 ± 1.6e+04, 3.0 %) | 4.059e+05 (4.098e+05 ± 1.9e+04, 4.5 %) | 3.079e+05 (3.102e+05 ± 6.9e+03, 2.2 %) | 5.78e+05 (5.775e+05 ± 2.5e+04, 4.4 %) | 3.083e+05 (3.169e+05 ± 1.7e+04, 5.5 %) | 5.598e+05 (5.701e+05 ± 1.7e+04, 3.0 %) | 2.509e+05 (2.489e+05 ± 4.8e+03, 1.9 %) | 2.971e+04 (3e+04 ± 1.4e+03, 4.6 %) | 1e+04 (1e+04 ± 53, 0.5 %) | 6075 (6098 ± 45, 0.7 %) | 5116 (5124 ± 21, 0.4 %) | 7.232e+04 (7.172e+04 ± 1.1e+03, 1.6 %) |
| tsan-dom-ea-lo-st-swmr | 5 | 5.299e+05 (5.229e+05 ± 2e+04, 3.8 %) | 8.248e+05 (8.245e+05 ± 4.2e+04, 5.1 %) | 3.56e+05 (3.595e+05 ± 9.4e+03, 2.6 %) | 4.64e+05 (4.679e+05 ± 1.1e+04, 2.3 %) | 4.655e+05 (4.624e+05 ± 1.2e+04, 2.5 %) | 2.872e+05 (2.881e+05 ± 9.5e+03, 3.3 %) | 2.681e+05 (2.647e+05 ± 6.1e+03, 2.3 %) | 5.222e+05 (5.274e+05 ± 1.6e+04, 3.0 %) | 4.1e+05 (4.116e+05 ± 1.1e+04, 2.6 %) | 3.193e+05 (3.156e+05 ± 1.2e+04, 3.9 %) | 5.527e+05 (5.616e+05 ± 2.8e+04, 5.0 %) | 3.14e+05 (3.135e+05 ± 8.1e+03, 2.6 %) | 5.909e+05 (5.751e+05 ± 3.6e+04, 6.2 %) | 2.477e+05 (2.472e+05 ± 4.3e+03, 1.7 %) | 2.819e+04 (2.837e+04 ± 9.2e+02, 3.2 %) | 9901 (9881 ± 72, 0.7 %) | 6055 (6057 ± 14, 0.2 %) | 5060 (5071 ± 33, 0.7 %) | 7.139e+04 (7.099e+04 ± 1.3e+03, 1.9 %) |
| tsan-dom_peeling | 5 | 5.305e+05 (5.297e+05 ± 5.9e+03, 1.1 %) | 8.2e+05 (8.109e+05 ± 5.4e+04, 6.6 %) | 3.784e+05 (3.642e+05 ± 2e+04, 5.6 %) | 4.636e+05 (4.66e+05 ± 8.4e+03, 1.8 %) | 4.671e+05 (4.634e+05 ± 1e+04, 2.2 %) | 2.907e+05 (2.899e+05 ± 5.3e+03, 1.8 %) | 2.705e+05 (2.677e+05 ± 6.9e+03, 2.6 %) | 5.241e+05 (5.182e+05 ± 3.3e+04, 6.4 %) | 3.978e+05 (3.994e+05 ± 8.1e+03, 2.0 %) | 3.074e+05 (3.105e+05 ± 1.3e+04, 4.3 %) | 5.847e+05 (5.793e+05 ± 2.3e+04, 4.0 %) | 3.182e+05 (3.159e+05 ± 1.2e+04, 3.8 %) | 5.976e+05 (5.739e+05 ± 3.7e+04, 6.4 %) | 2.464e+05 (2.451e+05 ± 3.7e+03, 1.5 %) | 2.862e+04 (2.901e+04 ± 9.3e+02, 3.2 %) | 1.006e+04 (1.007e+04 ± 43, 0.4 %) | 6171 (6167 ± 31, 0.5 %) | 5170 (5163 ± 17, 0.3 %) | 6.915e+04 (6.823e+04 ± 2.9e+03, 4.2 %) |
| tsan-dom_peeling-ea-lo-st-swmr | 5 | 5.42e+05 (5.37e+05 ± 8e+03, 1.5 %) | 7.614e+05 (7.856e+05 ± 4.7e+04, 6.0 %) | 3.597e+05 (3.625e+05 ± 1.9e+04, 5.3 %) | 4.749e+05 (4.802e+05 ± 1.3e+04, 2.7 %) | 4.675e+05 (4.662e+05 ± 3e+03, 0.6 %) | 2.935e+05 (2.921e+05 ± 9.5e+03, 3.2 %) | 2.701e+05 (2.709e+05 ± 7.6e+03, 2.8 %) | 5.402e+05 (5.382e+05 ± 1.3e+04, 2.4 %) | 4.115e+05 (4.133e+05 ± 1.6e+04, 3.8 %) | 3.08e+05 (3.15e+05 ± 1.6e+04, 5.2 %) | 5.643e+05 (5.728e+05 ± 2.3e+04, 4.1 %) | 3.148e+05 (3.188e+05 ± 8.8e+03, 2.8 %) | 5.64e+05 (5.706e+05 ± 2.9e+04, 5.1 %) | 2.54e+05 (2.539e+05 ± 2.2e+03, 0.8 %) | 2.801e+04 (2.848e+04 ± 7.5e+02, 2.6 %) | 9855 (9835 ± 58, 0.6 %) | 6010 (5996 ± 33, 0.6 %) | 4991 (4994 ± 9, 0.2 %) | 6.951e+04 (6.974e+04 ± 2.7e+03, 3.9 %) |
| tsan-dom_peeling-ea-lo-st-swmr-wp | 5 | 5.336e+05 (5.318e+05 ± 1e+04, 1.9 %) | 8.536e+05 (8.363e+05 ± 3.5e+04, 4.2 %) | 3.814e+05 (3.781e+05 ± 8e+03, 2.1 %) | 4.804e+05 (4.806e+05 ± 8.5e+03, 1.8 %) | 4.77e+05 (4.732e+05 ± 8.2e+03, 1.7 %) | 2.927e+05 (2.939e+05 ± 5.7e+03, 1.9 %) | 2.695e+05 (2.697e+05 ± 5.1e+03, 1.9 %) | 5.296e+05 (5.272e+05 ± 6.7e+03, 1.3 %) | 4.054e+05 (4.075e+05 ± 1.6e+04, 4.0 %) | 3.111e+05 (3.123e+05 ± 1e+04, 3.2 %) | 5.577e+05 (5.759e+05 ± 2.6e+04, 4.6 %) | 3.221e+05 (3.241e+05 ± 1e+04, 3.1 %) | 5.63e+05 (5.649e+05 ± 2.9e+04, 5.1 %) | 2.563e+05 (2.557e+05 ± 3.6e+03, 1.4 %) | 3.029e+04 (3.048e+04 ± 1.1e+03, 3.7 %) | 1.017e+04 (1.019e+04 ± 56, 0.6 %) | 6186 (6202 ± 37, 0.6 %) | 5196 (5177 ± 28, 0.5 %) | 6.957e+04 (6.892e+04 ± 2.7e+03, 3.9 %) |
| tsan-ea | 5 | 5.385e+05 (5.309e+05 ± 1.5e+04, 2.9 %) | 8.407e+05 (8.141e+05 ± 4.8e+04, 5.9 %) | 3.732e+05 (3.691e+05 ± 8.8e+03, 2.4 %) | 4.606e+05 (4.614e+05 ± 8.3e+03, 1.8 %) | 4.674e+05 (4.649e+05 ± 1.1e+04, 2.4 %) | 2.929e+05 (2.901e+05 ± 4.7e+03, 1.6 %) | 2.666e+05 (2.661e+05 ± 2.9e+03, 1.1 %) | 5.222e+05 (5.289e+05 ± 1.1e+04, 2.2 %) | 4.049e+05 (4.046e+05 ± 3.4e+03, 0.8 %) | 3.044e+05 (3.105e+05 ± 1.3e+04, 4.1 %) | 5.987e+05 (5.828e+05 ± 2.8e+04, 4.8 %) | 3.024e+05 (3.033e+05 ± 4.4e+03, 1.4 %) | 5.773e+05 (5.664e+05 ± 2e+04, 3.6 %) | 2.519e+05 (2.476e+05 ± 6.5e+03, 2.6 %) | 2.903e+04 (2.868e+04 ± 9.9e+02, 3.5 %) | 9795 (9819 ± 59, 0.6 %) | 5989 (5985 ± 22, 0.4 %) | 5011 (5008 ± 31, 0.6 %) | 6.862e+04 (6.975e+04 ± 2e+03, 2.9 %) |
| tsan-lo | 5 | 5.241e+05 (5.138e+05 ± 3e+04, 5.9 %) | 8.302e+05 (8.046e+05 ± 4.3e+04, 5.4 %) | 3.605e+05 (3.649e+05 ± 1.7e+04, 4.7 %) | 4.715e+05 (4.71e+05 ± 7.5e+03, 1.6 %) | 4.704e+05 (4.681e+05 ± 1e+04, 2.2 %) | 2.937e+05 (2.913e+05 ± 4.7e+03, 1.6 %) | 2.688e+05 (2.657e+05 ± 6.6e+03, 2.5 %) | 5.328e+05 (5.356e+05 ± 1.8e+04, 3.3 %) | 4.105e+05 (4.121e+05 ± 1.2e+04, 3.0 %) | 3.193e+05 (3.176e+05 ± 2e+04, 6.2 %) | 5.63e+05 (5.738e+05 ± 2.5e+04, 4.4 %) | 3.267e+05 (3.204e+05 ± 1.2e+04, 3.6 %) | 5.431e+05 (5.602e+05 ± 2.7e+04, 4.9 %) | 2.457e+05 (2.471e+05 ± 5e+03, 2.0 %) | 2.784e+04 (2.827e+04 ± 9.3e+02, 3.3 %) | 9743 (9756 ± 47, 0.5 %) | 5995 (5988 ± 36, 0.6 %) | 4997 (5006 ± 17, 0.3 %) | 7.088e+04 (7.106e+04 ± 1.5e+03, 2.1 %) |
| tsan-sound | 5 | 5.249e+05 (5.259e+05 ± 1.5e+04, 2.8 %) | 8.493e+05 (8.254e+05 ± 4.6e+04, 5.5 %) | 3.726e+05 (3.719e+05 ± 7.6e+03, 2.0 %) | 4.584e+05 (4.643e+05 ± 1.3e+04, 2.8 %) | 4.689e+05 (4.624e+05 ± 1.3e+04, 2.7 %) | 2.867e+05 (2.877e+05 ± 1.1e+04, 3.8 %) | 2.611e+05 (2.568e+05 ± 7.6e+03, 2.9 %) | 5.293e+05 (5.251e+05 ± 1.8e+04, 3.5 %) | 4.08e+05 (4.052e+05 ± 9.1e+03, 2.2 %) | 2.976e+05 (3.038e+05 ± 1.2e+04, 3.9 %) | 5.834e+05 (5.788e+05 ± 2.5e+04, 4.3 %) | 3.062e+05 (3.114e+05 ± 1e+04, 3.3 %) | 5.72e+05 (5.89e+05 ± 2.5e+04, 4.3 %) | 2.44e+05 (2.424e+05 ± 4.6e+03, 1.9 %) | 2.787e+04 (2.81e+04 ± 1e+03, 3.6 %) | 9699 (9711 ± 51, 0.5 %) | 5952 (5950 ± 29, 0.5 %) | 4968 (4976 ± 28, 0.6 %) | 7.024e+04 (7.017e+04 ± 1.3e+03, 1.9 %) |
| tsan-sound-wp | 5 | 5.03e+05 (5.112e+05 ± 2.9e+04, 5.7 %) | 8.529e+05 (8.452e+05 ± 1.4e+04, 1.6 %) | 3.581e+05 (3.57e+05 ± 1.3e+04, 3.6 %) | 4.715e+05 (4.78e+05 ± 1.2e+04, 2.6 %) | 4.724e+05 (4.678e+05 ± 2e+04, 4.2 %) | 2.948e+05 (2.906e+05 ± 9.5e+03, 3.3 %) | 2.708e+05 (2.621e+05 ± 1.3e+04, 4.9 %) | 5.367e+05 (5.329e+05 ± 1.8e+04, 3.4 %) | 4.073e+05 (4.058e+05 ± 2.1e+04, 5.1 %) | 3.037e+05 (3.074e+05 ± 1.1e+04, 3.7 %) | 5.92e+05 (5.819e+05 ± 2.1e+04, 3.6 %) | 3.164e+05 (3.15e+05 ± 1.4e+04, 4.5 %) | 5.75e+05 (5.752e+05 ± 1.9e+04, 3.3 %) | 2.51e+05 (2.517e+05 ± 7.3e+03, 2.9 %) | 2.851e+04 (2.911e+04 ± 1.2e+03, 4.0 %) | 9997 (9991 ± 41, 0.4 %) | 6091 (6071 ± 50, 0.8 %) | 5090 (5080 ± 35, 0.7 %) | 7.119e+04 (7.062e+04 ± 2e+03, 2.8 %) |
| tsan-st | 5 | 5.246e+05 (5.264e+05 ± 1.9e+04, 3.6 %) | 8.358e+05 (8.114e+05 ± 5e+04, 6.1 %) | 3.781e+05 (3.666e+05 ± 1.8e+04, 5.0 %) | 4.724e+05 (4.729e+05 ± 2e+04, 4.3 %) | 4.732e+05 (4.718e+05 ± 9.9e+03, 2.1 %) | 2.957e+05 (2.924e+05 ± 6e+03, 2.0 %) | 2.665e+05 (2.681e+05 ± 4.6e+03, 1.7 %) | 5.313e+05 (5.341e+05 ± 1.7e+04, 3.2 %) | 3.968e+05 (4.022e+05 ± 1.9e+04, 4.6 %) | 3.231e+05 (3.21e+05 ± 7.2e+03, 2.2 %) | 5.624e+05 (5.68e+05 ± 2.7e+04, 4.7 %) | 3.28e+05 (3.228e+05 ± 1.8e+04, 5.7 %) | 5.82e+05 (5.705e+05 ± 2.5e+04, 4.4 %) | 2.503e+05 (2.488e+05 ± 4.7e+03, 1.9 %) | 2.898e+04 (2.873e+04 ± 1.4e+03, 4.8 %) | 9735 (9736 ± 84, 0.9 %) | 5970 (5968 ± 27, 0.5 %) | 4962 (4968 ± 36, 0.7 %) | 7.014e+04 (6.917e+04 ± 3.2e+03, 4.6 %) |
| tsan-stmt | 5 | 5.186e+05 (5.097e+05 ± 1.8e+04, 3.5 %) | 7.292e+05 (7.609e+05 ± 5.4e+04, 7.1 %) | 3.531e+05 (3.531e+05 ± 1.5e+04, 4.2 %) | 4.583e+05 (4.548e+05 ± 1.2e+04, 2.7 %) | 4.568e+05 (4.527e+05 ± 1.5e+04, 3.3 %) | 2.888e+05 (2.867e+05 ± 6.4e+03, 2.2 %) | 2.642e+05 (2.637e+05 ± 5.8e+03, 2.2 %) | 5.249e+05 (5.236e+05 ± 1.3e+04, 2.4 %) | 3.87e+05 (3.871e+05 ± 1.3e+04, 3.2 %) | 2.956e+05 (2.949e+05 ± 6.1e+03, 2.1 %) | 5.614e+05 (5.629e+05 ± 2.4e+04, 4.2 %) | 3.193e+05 (3.156e+05 ± 8.7e+03, 2.8 %) | 5.446e+05 (5.394e+05 ± 1.9e+04, 3.6 %) | 2.428e+05 (2.439e+05 ± 6.8e+03, 2.8 %) | 2.713e+04 (2.694e+04 ± 6.6e+02, 2.4 %) | 9077 (9079 ± 21, 0.2 %) | 5533 (5535 ± 39, 0.7 %) | 4629 (4620 ± 19, 0.4 %) | 6.508e+04 (6.605e+04 ± 2.2e+03, 3.3 %) |
| tsan-swmr | 5 | 5.341e+05 (5.331e+05 ± 5.8e+03, 1.1 %) | 8.358e+05 (8.212e+05 ± 4e+04, 4.9 %) | 3.625e+05 (3.67e+05 ± 1.1e+04, 2.9 %) | 4.717e+05 (4.789e+05 ± 1.6e+04, 3.2 %) | 4.717e+05 (4.735e+05 ± 5.4e+03, 1.1 %) | 2.905e+05 (2.896e+05 ± 8.5e+03, 2.9 %) | 2.61e+05 (2.639e+05 ± 6.1e+03, 2.3 %) | 5.385e+05 (5.4e+05 ± 6.8e+03, 1.3 %) | 4.064e+05 (4.027e+05 ± 1.4e+04, 3.4 %) | 3.205e+05 (3.211e+05 ± 1.4e+04, 4.3 %) | 5.595e+05 (5.632e+05 ± 1.4e+04, 2.6 %) | 3.176e+05 (3.189e+05 ± 1.2e+04, 3.7 %) | 5.595e+05 (5.719e+05 ± 1.9e+04, 3.4 %) | 2.455e+05 (2.483e+05 ± 4.3e+03, 1.7 %) | 2.818e+04 (2.83e+04 ± 9.3e+02, 3.3 %) | 9771 (9758 ± 33, 0.3 %) | 5980 (5967 ± 30, 0.5 %) | 4980 (4985 ± 31, 0.6 %) | 6.89e+04 (6.884e+04 ± 2.7e+03, 3.9 %) |

##### Speedup vs stock TSan (SU) and slowdown vs native (SD), on medians; geometric mean over tests; 95 % bootstrap interval

**SU stable** repeats the speedup over the 18 of 19 subtests whose pooled run-to-run CV, taken over every configuration rather than off the baseline alone, is at most 5 %. The set is a property of the workload, not of a configuration, and applies to every row alike. Excluded here: `PING_MBULK` (pooled CV 5.5 %). Report the all-subtest column as the headline and this one as what the data can resolve.

| config | label | N | SU geomean [95 %] | SU stable [95 %] | SD geomean [95 %] | static sites | modes | per-test SU |
|---|---|---|---|---|---|---|---|---|
| orig | orig | 5 | 7.934 [7.747, 8.148] | 7.896 [7.708, 8.108] | — | 0 | pinned | PING_INLINE:8.07, PING_MBULK:8.66, SET:9.22, GET:8.52, INCR:9.17, RPUSH:10.86, LPOP:11.25, RPOP:9.01, SADD:8.81, HSET:8.87, SPOP:9.61, ZADD:8.51, ZPOPMIN:9.42, LPUSH:11.78, LRANGE_100:5.20, LRANGE_300:4.39, LRANGE_500:4.24, LRANGE_600:4.13, MSET:7.85 |
| tsan | tsan | 5 | — | — | 7.93 [7.75, 8.15] | 37941 | pinned |  |
| tsan-dom | tsan-dom | 5 | 1.020 [1.002, 1.045] | 1.016 [1.001, 1.043] | 7.78 [7.59, 7.93] | 37396 | pinned | PING_INLINE:0.98, PING_MBULK:1.09, SET:1.01, GET:1.01, INCR:1.01, RPUSH:1.02, LPOP:1.06, RPOP:1.04, SADD:1.00, HSET:0.97, SPOP:1.03, ZADD:0.99, ZPOPMIN:1.00, LPUSH:1.04, LRANGE_100:1.02, LRANGE_300:1.03, LRANGE_500:1.02, LRANGE_600:1.02, MSET:1.05 |
| tsan-dom-ea-lo-st-swmr | AllOpt-peel | 5 | 1.010 [0.991, 1.033] | 1.007 [0.988, 1.030] | 7.85 [7.68, 8.04] | 37077 | pinned | PING_INLINE:0.97, PING_MBULK:1.08, SET:0.98, GET:0.99, INCR:1.00, RPUSH:0.99, LPOP:1.04, RPOP:1.01, SADD:1.01, HSET:1.01, SPOP:0.98, ZADD:1.01, ZPOPMIN:1.06, LPUSH:1.03, LRANGE_100:0.97, LRANGE_300:1.02, LRANGE_500:1.02, LRANGE_600:1.01, MSET:1.04 |
| tsan-dom_peeling | tsan-dom_peeling | 5 | 1.017 [0.989, 1.035] | 1.014 [0.989, 1.034] | 7.80 [7.67, 8.03] | 43668 | pinned | PING_INLINE:0.97, PING_MBULK:1.07, SET:1.04, GET:0.99, INCR:1.00, RPUSH:1.00, LPOP:1.05, RPOP:1.01, SADD:0.98, HSET:0.97, SPOP:1.04, ZADD:1.02, ZPOPMIN:1.07, LPUSH:1.02, LRANGE_100:0.98, LRANGE_300:1.03, LRANGE_500:1.04, LRANGE_600:1.03, MSET:1.01 |
| tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 5 | 1.008 [0.994, 1.038] | 1.009 [0.994, 1.039] | 7.87 [7.64, 8.00] | 43292 | pinned | PING_INLINE:0.99, PING_MBULK:0.99, SET:0.99, GET:1.01, INCR:1.00, RPUSH:1.01, LPOP:1.05, RPOP:1.04, SADD:1.01, HSET:0.98, SPOP:1.00, ZADD:1.01, ZPOPMIN:1.01, LPUSH:1.06, LRANGE_100:0.96, LRANGE_300:1.01, LRANGE_500:1.01, LRANGE_600:1.00, MSET:1.01 |
| tsan-dom_peeling-ea-lo-st-swmr-wp | AllOpt+peel (WP summaries) | 5 | 1.027 [1.008, 1.051] | 1.022 [1.007, 1.049] | 7.72 [7.55, 7.88] | 40692 | pinned | PING_INLINE:0.98, PING_MBULK:1.12, SET:1.05, GET:1.03, INCR:1.02, RPUSH:1.01, LPOP:1.05, RPOP:1.02, SADD:1.00, HSET:0.98, SPOP:0.99, ZADD:1.04, ZPOPMIN:1.01, LPUSH:1.07, LRANGE_100:1.04, LRANGE_300:1.04, LRANGE_500:1.04, LRANGE_600:1.04, MSET:1.01 |
| tsan-ea | tsan-ea | 5 | 1.012 [0.988, 1.029] | 1.007 [0.988, 1.028] | 7.84 [7.71, 8.05] | 37608 | pinned | PING_INLINE:0.99, PING_MBULK:1.10, SET:1.03, GET:0.98, INCR:1.00, RPUSH:1.01, LPOP:1.04, RPOP:1.01, SADD:1.00, HSET:0.96, SPOP:1.06, ZADD:0.97, ZPOPMIN:1.03, LPUSH:1.05, LRANGE_100:0.99, LRANGE_300:1.00, LRANGE_500:1.00, LRANGE_600:1.00, MSET:1.00 |
| tsan-lo | tsan-lo | 5 | 1.010 [0.989, 1.034] | 1.006 [0.988, 1.033] | 7.86 [7.67, 8.04] | 37941 | pinned | PING_INLINE:0.96, PING_MBULK:1.08, SET:0.99, GET:1.01, INCR:1.01, RPUSH:1.01, LPOP:1.05, RPOP:1.03, SADD:1.01, HSET:1.01, SPOP:1.00, ZADD:1.05, ZPOPMIN:0.97, LPUSH:1.02, LRANGE_100:0.95, LRANGE_300:1.00, LRANGE_500:1.01, LRANGE_600:1.00, MSET:1.03 |
| tsan-sound | tsan-sound | 5 | 1.003 [0.984, 1.027] | 0.998 [0.982, 1.024] | 7.91 [7.73, 8.08] | 37608 | pinned | PING_INLINE:0.96, PING_MBULK:1.11, SET:1.03, GET:0.98, INCR:1.01, RPUSH:0.99, LPOP:1.02, RPOP:1.02, SADD:1.00, HSET:0.94, SPOP:1.04, ZADD:0.98, ZPOPMIN:1.02, LPUSH:1.01, LRANGE_100:0.95, LRANGE_300:1.00, LRANGE_500:1.00, LRANGE_600:0.99, MSET:1.02 |
| tsan-sound-wp | sound (WP summaries) | 5 | 1.017 [0.994, 1.038] | 1.011 [0.990, 1.035] | 7.80 [7.64, 8.01] | 35372 | pinned | PING_INLINE:0.92, PING_MBULK:1.11, SET:0.99, GET:1.01, INCR:1.01, RPUSH:1.02, LPOP:1.05, RPOP:1.03, SADD:1.00, HSET:0.96, SPOP:1.05, ZADD:1.02, ZPOPMIN:1.03, LPUSH:1.04, LRANGE_100:0.98, LRANGE_300:1.03, LRANGE_500:1.02, LRANGE_600:1.02, MSET:1.04 |
| tsan-st | tsan-st | 5 | 1.017 [0.991, 1.037] | 1.014 [0.990, 1.036] | 7.80 [7.65, 8.03] | 37941 | pinned | PING_INLINE:0.96, PING_MBULK:1.09, SET:1.04, GET:1.01, INCR:1.02, RPUSH:1.02, LPOP:1.04, RPOP:1.02, SADD:0.98, HSET:1.02, SPOP:1.00, ZADD:1.05, ZPOPMIN:1.04, LPUSH:1.04, LRANGE_100:0.99, LRANGE_300:1.00, LRANGE_500:1.00, LRANGE_600:0.99, MSET:1.02 |
| tsan-stmt | tsan-stmt | 5 | 0.969 [0.950, 0.990] | 0.970 [0.951, 0.990] | 8.19 [7.99, 8.37] | 37882 | pinned | PING_INLINE:0.95, PING_MBULK:0.95, SET:0.97, GET:0.98, INCR:0.98, RPUSH:1.00, LPOP:1.03, RPOP:1.01, SADD:0.95, HSET:0.94, SPOP:1.00, ZADD:1.03, ZPOPMIN:0.97, LPUSH:1.01, LRANGE_100:0.93, LRANGE_300:0.93, LRANGE_500:0.93, LRANGE_600:0.92, MSET:0.95 |
| tsan-swmr | tsan-swmr | 5 | 1.008 [0.993, 1.035] | 1.004 [0.990, 1.033] | 7.87 [7.67, 8.01] | 37941 | pinned | PING_INLINE:0.98, PING_MBULK:1.09, SET:1.00, GET:1.01, INCR:1.01, RPUSH:1.00, LPOP:1.02, RPOP:1.04, SADD:1.00, HSET:1.01, SPOP:0.99, ZADD:1.02, ZPOPMIN:1.00, LPUSH:1.02, LRANGE_100:0.96, LRANGE_300:1.00, LRANGE_500:1.00, LRANGE_600:0.99, MSET:1.00 |

#### sqlite

Session: mode=pinned cpuset=4-27,60-83 governor=powersave no_turbo=0 host=focs-server started=2026-09-08T10:53:28

| config | N | walthread1 median (mean ± σ, CV) | walthread2 median (mean ± σ, CV) | dynamic_triggers median (mean ± σ, CV) | checkpoint_starvation_1 median (mean ± σ, CV) | checkpoint_starvation_2 median (mean ± σ, CV) | stress1 median (mean ± σ, CV) | stress2 median (mean ± σ, CV) |
|---|---|---|---|---|---|---|---|---|
| orig | 5 | 4745 (4693 ± 2.4e+02, 5.0 %) | 1.698e+04 (1.688e+04 ± 4.5e+02, 2.7 %) | 6.716e+05 (7.122e+05 ± 1.6e+05, 22.8 %) | 1.027e+06 (1.021e+06 ± 2.3e+04, 2.2 %) | 782 (782 ± 0, 0.0 %) | 5.389e+05 (5.229e+05 ± 7.3e+04, 13.9 %) | 1.883e+05 (1.872e+05 ± 1.7e+03, 0.9 %) |
| tsan | 5 | 2839 (2825 ± 32, 1.1 %) | 6840 (6850 ± 27, 0.4 %) | 1.492e+05 (1.475e+05 ± 3e+04, 20.6 %) | 1.808e+05 (1.805e+05 ± 1.6e+03, 0.9 %) | 766 (766 ± 0, 0.0 %) | 1.023e+05 (1.056e+05 ± 6.8e+03, 6.4 %) | 3.26e+04 (3.266e+04 ± 6.4e+02, 2.0 %) |
| tsan-dom | 5 | 2838 (2818 ± 46, 1.6 %) | 6846 (6853 ± 78, 1.1 %) | 1.384e+05 (1.531e+05 ± 3.1e+04, 20.3 %) | 1.815e+05 (1.818e+05 ± 1.3e+03, 0.7 %) | 766 (766 ± 0, 0.0 %) | 9.998e+04 (1.161e+05 ± 3.5e+04, 30.6 %) | 3.063e+04 (3.03e+04 ± 2.5e+03, 8.4 %) |
| tsan-dom-ea-lo-st-swmr | 5 | 2823 (2818 ± 11, 0.4 %) | 6885 (6893 ± 34, 0.5 %) | 1.526e+05 (1.454e+05 ± 2.7e+04, 18.5 %) | 1.828e+05 (1.83e+05 ± 1.5e+03, 0.8 %) | 766 (766 ± 0, 0.0 %) | 1.286e+05 (1.164e+05 ± 2e+04, 16.9 %) | 3.214e+04 (3.16e+04 ± 2.2e+03, 7.1 %) |
| tsan-dom_peeling | 5 | 2793 (2800 ± 23, 0.8 %) | 6884 (6870 ± 46, 0.7 %) | 1.392e+05 (1.324e+05 ± 1.1e+04, 8.1 %) | 1.823e+05 (1.823e+05 ± 1.9e+03, 1.0 %) | 766 (766 ± 0, 0.0 %) | 9.709e+04 (1.012e+05 ± 1.3e+04, 12.9 %) | 3.168e+04 (3.156e+04 ± 6.2e+02, 1.9 %) |
| tsan-dom_peeling-ea-lo-st-swmr | 5 | 2799 (2802 ± 16, 0.6 %) | 6853 (6837 ± 38, 0.6 %) | 1.26e+05 (1.259e+05 ± 1.6e+04, 12.7 %) | 1.846e+05 (1.844e+05 ± 2.6e+03, 1.4 %) | 766 (766 ± 0, 0.0 %) | 1.238e+05 (1.247e+05 ± 2.6e+04, 21.0 %) | 3.147e+04 (3.185e+04 ± 1.2e+03, 3.7 %) |
| tsan-dom_peeling-ea-lo-st-swmr-wp | 5 | 2830 (2809 ± 71, 2.5 %) | 6884 (6836 ± 1e+02, 1.5 %) | 1.358e+05 (1.331e+05 ± 1.3e+04, 9.5 %) | 1.816e+05 (1.79e+05 ± 7.5e+03, 4.2 %) | 766 (766 ± 0, 0.0 %) | 1.109e+05 (1.128e+05 ± 1.9e+04, 16.7 %) | 3.127e+04 (3.142e+04 ± 1.1e+03, 3.4 %) |
| tsan-ea | 5 | 2790 (2796 ± 19, 0.7 %) | 6898 (6872 ± 60, 0.9 %) | 1.436e+05 (1.441e+05 ± 6.2e+03, 4.3 %) | 1.841e+05 (1.83e+05 ± 1.6e+03, 0.9 %) | 766 (766 ± 0, 0.0 %) | 1.045e+05 (1.148e+05 ± 2.7e+04, 23.9 %) | 3.211e+04 (3.191e+04 ± 1.6e+03, 5.1 %) |
| tsan-lo | 5 | 2791 (2787 ± 16, 0.6 %) | 6862 (6863 ± 76, 1.1 %) | 1.26e+05 (1.316e+05 ± 1.9e+04, 14.2 %) | 1.796e+05 (1.807e+05 ± 1.7e+03, 1.0 %) | 766 (766 ± 0, 0.0 %) | 1.029e+05 (1.097e+05 ± 2.6e+04, 24.1 %) | 3.024e+04 (3.02e+04 ± 2.3e+03, 7.6 %) |
| tsan-sound | 5 | 2812 (2820 ± 19, 0.7 %) | 6824 (6856 ± 59, 0.9 %) | 1.252e+05 (1.222e+05 ± 1e+04, 8.5 %) | 1.849e+05 (1.838e+05 ± 1.6e+03, 0.9 %) | 766 (766 ± 0, 0.0 %) | 1.156e+05 (1.156e+05 ± 1.5e+04, 13.2 %) | 3.202e+04 (3.135e+04 ± 2.6e+03, 8.3 %) |
| tsan-sound-wp | 5 | 2802 (2793 ± 26, 0.9 %) | 6839 (6776 ± 1.4e+02, 2.0 %) | 1.674e+05 (1.64e+05 ± 3.5e+04, 21.2 %) | 1.81e+05 (1.812e+05 ± 2.2e+03, 1.2 %) | 766 (766 ± 0, 0.0 %) | 1.072e+05 (1.107e+05 ± 1.9e+04, 16.7 %) | 3.316e+04 (3.287e+04 ± 8.9e+02, 2.7 %) |
| tsan-st | 5 | 2802 (2802 ± 47, 1.7 %) | 6920 (6890 ± 52, 0.8 %) | 1.342e+05 (1.423e+05 ± 2.5e+04, 17.8 %) | 1.804e+05 (1.801e+05 ± 1.7e+03, 0.9 %) | 766 (766 ± 0, 0.0 %) | 1.177e+05 (1.122e+05 ± 1.7e+04, 15.1 %) | 3.172e+04 (3.185e+04 ± 9.4e+02, 3.0 %) |
| tsan-stmt | 5 | 2758 (2760 ± 14, 0.5 %) | 6685 (6705 ± 40, 0.6 %) | 1.426e+05 (1.551e+05 ± 2.2e+04, 14.4 %) | 1.779e+05 (1.783e+05 ± 1.9e+03, 1.1 %) | 766 (766 ± 0, 0.0 %) | 1.085e+05 (1.214e+05 ± 3.1e+04, 25.9 %) | 3.164e+04 (3.105e+04 ± 1.3e+03, 4.2 %) |
| tsan-swmr | 5 | 2826 (2831 ± 19, 0.7 %) | 6857 (6876 ± 54, 0.8 %) | 1.31e+05 (1.384e+05 ± 2.5e+04, 18.3 %) | 1.832e+05 (1.827e+05 ± 1.6e+03, 0.9 %) | 766 (766 ± 0, 0.0 %) | 1.147e+05 (1.301e+05 ± 3.4e+04, 25.9 %) | 3.132e+04 (2.989e+04 ± 2.8e+03, 9.4 %) |

##### Speedup vs stock TSan (SU) and slowdown vs native (SD), on medians; geometric mean over tests; 95 % bootstrap interval

**SU stable** repeats the speedup over the 4 of 7 subtests whose pooled run-to-run CV, taken over every configuration rather than off the baseline alone, is at most 5 %. The set is a property of the workload, not of a configuration, and applies to every row alike. Excluded here: `dynamic_triggers` (pooled CV 16.1 %); `stress1` (pooled CV 19.9 %); `stress2` (pooled CV 5.5 %). Report the all-subtest column as the headline and this one as what the data can resolve.

| config | label | N | SU geomean [95 %] | SU stable [95 %] | SD geomean [95 %] | static sites | modes | per-test SU |
|---|---|---|---|---|---|---|---|---|
| orig | orig | 5 | 3.181 [2.937, 3.482] | 2.214 [2.136, 2.256] | — | 0 | pinned | walthread1:1.67, walthread2:2.48, dynamic_triggers:4.50, checkpoint_starvation_1:5.68, checkpoint_starvation_2:1.02, stress1:5.27, stress2:5.78 |
| tsan | tsan | 5 | — | — | 3.18 [2.94, 3.48] | 57996 | pinned |  |
| tsan-dom | tsan-dom | 5 | 0.978 [0.924, 1.126] | 1.001 [0.989, 1.012] | 3.25 [2.80, 3.49] | 57033 | pinned | walthread1:1.00, walthread2:1.00, dynamic_triggers:0.93, checkpoint_starvation_1:1.00, checkpoint_starvation_2:1.00, stress1:0.98, stress2:0.94 |
| tsan-dom-ea-lo-st-swmr | AllOpt-peel | 5 | 1.036 [0.924, 1.110] | 1.003 [0.997, 1.012] | 3.07 [2.89, 3.47] | 56087 | pinned | walthread1:0.99, walthread2:1.01, dynamic_triggers:1.02, checkpoint_starvation_1:1.01, checkpoint_starvation_2:1.00, stress1:1.26, stress2:0.99 |
| tsan-dom_peeling | tsan-dom_peeling | 5 | 0.978 [0.920, 1.050] | 1.000 [0.992, 1.010] | 3.25 [3.03, 3.51] | 62996 | pinned | walthread1:0.98, walthread2:1.01, dynamic_triggers:0.93, checkpoint_starvation_1:1.01, checkpoint_starvation_2:1.00, stress1:0.95, stress2:0.97 |
| tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 5 | 0.999 [0.921, 1.098] | 1.002 [0.994, 1.013] | 3.18 [2.93, 3.49] | 61931 | pinned | walthread1:0.99, walthread2:1.00, dynamic_triggers:0.84, checkpoint_starvation_1:1.02, checkpoint_starvation_2:1.00, stress1:1.21, stress2:0.97 |
| tsan-dom_peeling-ea-lo-st-swmr-wp | AllOpt+peel (WP summaries) | 5 | 0.993 [0.923, 1.074] | 1.002 [0.969, 1.014] | 3.20 [2.98, 3.50] | 61827 | pinned | walthread1:1.00, walthread2:1.01, dynamic_triggers:0.91, checkpoint_starvation_1:1.00, checkpoint_starvation_2:1.00, stress1:1.08, stress2:0.96 |
| tsan-ea | tsan-ea | 5 | 0.997 [0.948, 1.110] | 1.002 [0.993, 1.011] | 3.19 [2.88, 3.43] | 57025 | pinned | walthread1:0.98, walthread2:1.01, dynamic_triggers:0.96, checkpoint_starvation_1:1.02, checkpoint_starvation_2:1.00, stress1:1.02, stress2:0.98 |
| tsan-lo | tsan-lo | 5 | 0.964 [0.899, 1.077] | 0.995 [0.988, 1.007] | 3.30 [2.97, 3.58] | 57996 | pinned | walthread1:0.98, walthread2:1.00, dynamic_triggers:0.84, checkpoint_starvation_1:0.99, checkpoint_starvation_2:1.00, stress1:1.01, stress2:0.93 |
| tsan-sound | tsan-sound | 5 | 0.991 [0.921, 1.062] | 1.003 [0.996, 1.013] | 3.21 [2.98, 3.49] | 57025 | pinned | walthread1:0.99, walthread2:1.00, dynamic_triggers:0.84, checkpoint_starvation_1:1.02, checkpoint_starvation_2:1.00, stress1:1.13, stress2:0.98 |
| tsan-sound-wp | sound (WP summaries) | 5 | 1.024 [0.941, 1.120] | 0.997 [0.983, 1.008] | 3.11 [2.85, 3.43] | 56890 | pinned | walthread1:0.99, walthread2:1.00, dynamic_triggers:1.12, checkpoint_starvation_1:1.00, checkpoint_starvation_2:1.00, stress1:1.05, stress2:1.02 |
| tsan-st | tsan-st | 5 | 1.000 [0.920, 1.093] | 0.999 [0.988, 1.010] | 3.18 [2.93, 3.48] | 57996 | pinned | walthread1:0.99, walthread2:1.01, dynamic_triggers:0.90, checkpoint_starvation_1:1.00, checkpoint_starvation_2:1.00, stress1:1.15, stress2:0.97 |
| tsan-stmt | tsan-stmt | 5 | 0.988 [0.942, 1.130] | 0.983 [0.978, 0.995] | 3.22 [2.85, 3.44] | 57957 | pinned | walthread1:0.97, walthread2:0.98, dynamic_triggers:0.96, checkpoint_starvation_1:0.98, checkpoint_starvation_2:1.00, stress1:1.06, stress2:0.97 |
| tsan-swmr | tsan-swmr | 5 | 0.994 [0.930, 1.118] | 1.003 [0.996, 1.013] | 3.20 [2.83, 3.46] | 57996 | pinned | walthread1:1.00, walthread2:1.00, dynamic_triggers:0.88, checkpoint_starvation_1:1.01, checkpoint_starvation_2:1.00, stress1:1.12, stress2:0.96 |

### Tables — yield-d98873cda906

Generated by `aggregate.py` from `results/yield-d98873cda906/`; regenerate with `python3 write_readme_results.py results/yield-d98873cda906`.

#### Cross-application summary

SU = speedup vs stock TSan, SD = slowdown vs native; geometric mean over the app's tests on per-test medians of N undisturbed runs; [95 % bootstrap interval]. **SU stable** is the same speedup over the subtests whose stock-TSan baseline CV is at most 5 %, the set chosen once from the baseline and applied to every configuration alike; it is empty where every subtest is inside that bound. Read SU as the headline and SU stable as what the data can resolve; the per-app file names the excluded subtests and their baseline CV.

| app | config | label | N | SU | SU stable | SD | static sites | modes |
|---|---|---|---|---|---|---|---|---|
| ffmpeg | orig | orig | 5 | 2.804 [2.738, 2.840] | — | — | 0 | pinned |
| ffmpeg | tsan | tsan | 5 | — | — | 2.80 [2.74, 2.84] | 514609 | pinned |
| ffmpeg | tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 5 | 1.000 [0.993, 1.011] | — | 2.80 [2.74, 2.83] | 541449 | pinned |
| ffmpeg | tsan-dom_peeling-ea-lo-st-swmr-yoff | tsan-dom_peeling-ea-lo-st-swmr-yoff | 5 | 1.003 [0.990, 1.014] | — | 2.80 [2.73, 2.83] | 542683 | pinned |
| ffmpeg | tsan-sound | tsan-sound | 5 | 0.996 [0.990, 1.010] | — | 2.82 [2.74, 2.84] | 497309 | pinned |
| ffmpeg | tsan-sound-yoff | tsan-sound-yoff | 5 | 0.996 [0.992, 1.008] | — | 2.81 [2.75, 2.84] | 497409 | pinned |
| ffmpeg | tsan-stmt | tsan-stmt | 5 | 1.114 [1.103, 1.124] | — | 2.52 [2.46, 2.55] | 514540 | pinned |
| ffmpeg | tsan-stmt-yoff | tsan-stmt-yoff | 5 | 1.105 [1.099, 1.119] | — | 2.54 [2.47, 2.56] | 514493 | pinned |
| ffmpeg | tsan-yoff | tsan-yoff | 5 | 0.991 [0.982, 1.002] | — | 2.83 [2.76, 2.86] | 514609 | pinned |
| memcached | orig | orig | 5 | 3.378 [3.271, 3.590] | — | — | 0 | pinned |
| memcached | tsan | tsan | 5 | — | — | 3.38 [3.27, 3.59] | 6748 | pinned |
| memcached | tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 5 | 1.012 [0.944, 1.059] | — | 3.34 [3.13, 3.75] | 7127 | pinned |
| memcached | tsan-dom_peeling-ea-lo-st-swmr-yoff | tsan-dom_peeling-ea-lo-st-swmr-yoff | 5 | 1.016 [0.978, 1.031] | — | 3.33 [3.22, 3.62] | 7130 | pinned |
| memcached | tsan-sound | tsan-sound | 5 | 1.005 [0.945, 1.026] | — | 3.36 [3.23, 3.75] | 6640 | pinned |
| memcached | tsan-sound-yoff | tsan-sound-yoff | 5 | 1.006 [0.970, 1.031] | — | 3.36 [3.22, 3.65] | 6643 | pinned |
| memcached | tsan-stmt | tsan-stmt | 5 | 0.998 [0.956, 1.008] | — | 3.39 [3.29, 3.70] | 6810 | pinned |
| memcached | tsan-stmt-yoff | tsan-stmt-yoff | 5 | 1.003 [0.943, 1.026] | — | 3.37 [3.23, 3.75] | 6810 | pinned |
| memcached | tsan-yoff | tsan-yoff | 5 | 1.019 [0.983, 1.034] | — | 3.31 [3.21, 3.60] | 6748 | pinned |
| redis | orig | orig | 5 | 7.993 [7.725, 8.068] | 7.855 [7.635, 7.950] | — | 0 | pinned |
| redis | tsan | tsan | 5 | — | — | 7.99 [7.73, 8.07] | 37941 | pinned |
| redis | tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 5 | 1.001 [0.954, 1.010] | 1.006 [0.966, 1.019] | 7.98 [7.82, 8.27] | 43242 | pinned |
| redis | tsan-dom_peeling-ea-lo-st-swmr-yoff | tsan-dom_peeling-ea-lo-st-swmr-yoff | 5 | 1.011 [0.981, 1.024] | 1.011 [0.991, 1.027] | 7.91 [7.72, 8.03] | 43291 | pinned |
| redis | tsan-sound | tsan-sound | 5 | 0.995 [0.968, 1.013] | 0.993 [0.976, 1.015] | 8.03 [7.80, 8.14] | 37604 | pinned |
| redis | tsan-sound-yoff | tsan-sound-yoff | 5 | 0.998 [0.970, 1.013] | 0.997 [0.978, 1.015] | 8.01 [7.80, 8.13] | 37607 | pinned |
| redis | tsan-stmt | tsan-stmt | 5 | 0.976 [0.945, 0.987] | 0.979 [0.955, 0.993] | 8.19 [8.01, 8.35] | 37878 | pinned |
| redis | tsan-stmt-yoff | tsan-stmt-yoff | 5 | 0.971 [0.942, 0.982] | 0.974 [0.954, 0.988] | 8.23 [8.04, 8.38] | 37882 | pinned |
| redis | tsan-yoff | tsan-yoff | 5 | 1.000 [0.975, 1.016] | 1.004 [0.985, 1.022] | 7.99 [7.78, 8.10] | 37941 | pinned |
| sqlite | orig | orig | 5 | 2.772 [2.540, 3.052] | 2.230 [2.161, 2.310] | — | 0 | pinned |
| sqlite | tsan | tsan | 5 | — | — | 2.77 [2.54, 3.05] | 57996 | pinned |
| sqlite | tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 5 | 0.989 [0.918, 1.101] | 1.002 [0.976, 1.024] | 2.80 [2.53, 3.04] | 61872 | pinned |
| sqlite | tsan-dom_peeling-ea-lo-st-swmr-yoff | tsan-dom_peeling-ea-lo-st-swmr-yoff | 5 | 0.991 [0.908, 1.057] | 0.986 [0.964, 1.012] | 2.80 [2.63, 3.09] | 61931 | pinned |
| sqlite | tsan-sound | tsan-sound | 5 | 0.961 [0.905, 1.046] | 0.983 [0.958, 1.018] | 2.88 [2.66, 3.09] | 57006 | pinned |
| sqlite | tsan-sound-yoff | tsan-sound-yoff | 5 | 1.008 [0.907, 1.083] | 0.996 [0.963, 1.023] | 2.75 [2.56, 3.08] | 57025 | pinned |
| sqlite | tsan-stmt | tsan-stmt | 5 | 1.012 [0.921, 1.087] | 0.980 [0.952, 1.010] | 2.74 [2.56, 3.04] | 57961 | pinned |
| sqlite | tsan-stmt-yoff | tsan-stmt-yoff | 5 | 1.004 [0.911, 1.075] | 0.972 [0.947, 1.002] | 2.76 [2.57, 3.05] | 57957 | pinned |
| sqlite | tsan-yoff | tsan-yoff | 5 | 1.015 [0.934, 1.095] | 1.004 [0.978, 1.034] | 2.73 [2.54, 3.01] | 57996 | pinned |

#### ffmpeg

Session: mode=pinned cpuset=4-27,60-83 governor=powersave no_turbo=0 host=focs-server started=2026-09-09T09:06:05

| config | N | h264_libx264 median (mean ± σ, CV) | copy_passthrough median (mean ± σ, CV) | mjpeg median (mean ± σ, CV) | h265_libx265 median (mean ± σ, CV) |
|---|---|---|---|---|---|
| orig | 5 | 36.97 (37.07 ± 0.18, 0.5 %) | 0.13 (0.134 ± 0.0055, 4.1 %) | 3.85 (3.832 ± 0.056, 1.5 %) | 40.9 (40.84 ± 0.13, 0.3 %) |
| tsan | 5 | 45.42 (45.46 ± 0.21, 0.5 %) | 0.74 (0.744 ± 0.011, 1.5 %) | 25.56 (25.59 ± 0.076, 0.3 %) | 54.45 (54.44 ± 0.086, 0.2 %) |
| tsan-dom_peeling-ea-lo-st-swmr | 5 | 45.43 (45.53 ± 0.2, 0.4 %) | 0.74 (0.742 ± 0.0084, 1.1 %) | 25.5 (25.51 ± 0.12, 0.5 %) | 54.46 (54.42 ± 0.12, 0.2 %) |
| tsan-dom_peeling-ea-lo-st-swmr-yoff | 5 | 45.43 (45.41 ± 0.15, 0.3 %) | 0.74 (0.746 ± 0.015, 2.0 %) | 25.22 (25.24 ± 0.087, 0.3 %) | 54.48 (54.45 ± 0.15, 0.3 %) |
| tsan-sound | 5 | 45.6 (45.54 ± 0.22, 0.5 %) | 0.75 (0.746 ± 0.011, 1.5 %) | 25.46 (25.47 ± 0.088, 0.3 %) | 54.64 (54.62 ± 0.091, 0.2 %) |
| tsan-sound-yoff | 5 | 45.49 (45.52 ± 0.21, 0.5 %) | 0.75 (0.746 ± 0.0055, 0.7 %) | 25.53 (25.52 ± 0.029, 0.1 %) | 54.54 (54.49 ± 0.15, 0.3 %) |
| tsan-stmt | 5 | 45.42 (45.6 ± 0.34, 0.7 %) | 0.47 (0.47 ± 0, 0.0 %) | 26.13 (26.28 ± 0.32, 1.2 %) | 54.49 (54.53 ± 0.067, 0.1 %) |
| tsan-stmt-yoff | 5 | 45.82 (45.77 ± 0.31, 0.7 %) | 0.48 (0.478 ± 0.0045, 0.9 %) | 26.18 (26.21 ± 0.096, 0.4 %) | 54.58 (54.55 ± 0.16, 0.3 %) |
| tsan-yoff | 5 | 45.6 (45.64 ± 0.18, 0.4 %) | 0.76 (0.76 ± 0.012, 1.6 %) | 25.68 (25.7 ± 0.1, 0.4 %) | 54.52 (54.51 ± 0.05, 0.1 %) |

##### Speedup vs stock TSan (SU) and slowdown vs native (SD), on medians; geometric mean over tests; 95 % bootstrap interval

| config | label | N | SU geomean [95 %] | SU stable [95 %] | SD geomean [95 %] | static sites | modes | per-test SU |
|---|---|---|---|---|---|---|---|---|
| orig | orig | 5 | 2.804 [2.738, 2.840] | — | — | 0 | pinned | h264_libx264:1.23, copy_passthrough:5.69, mjpeg:6.64, h265_libx265:1.33 |
| tsan | tsan | 5 | — | — | 2.80 [2.74, 2.84] | 514609 | pinned |  |
| tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 5 | 1.000 [0.993, 1.011] | — | 2.80 [2.74, 2.83] | 541449 | pinned | h264_libx264:1.00, copy_passthrough:1.00, mjpeg:1.00, h265_libx265:1.00 |
| tsan-dom_peeling-ea-lo-st-swmr-yoff | tsan-dom_peeling-ea-lo-st-swmr-yoff | 5 | 1.003 [0.990, 1.014] | — | 2.80 [2.73, 2.83] | 542683 | pinned | h264_libx264:1.00, copy_passthrough:1.00, mjpeg:1.01, h265_libx265:1.00 |
| tsan-sound | tsan-sound | 5 | 0.996 [0.990, 1.010] | — | 2.82 [2.74, 2.84] | 497309 | pinned | h264_libx264:1.00, copy_passthrough:0.99, mjpeg:1.00, h265_libx265:1.00 |
| tsan-sound-yoff | tsan-sound-yoff | 5 | 0.996 [0.992, 1.008] | — | 2.81 [2.75, 2.84] | 497409 | pinned | h264_libx264:1.00, copy_passthrough:0.99, mjpeg:1.00, h265_libx265:1.00 |
| tsan-stmt | tsan-stmt | 5 | 1.114 [1.103, 1.124] | — | 2.52 [2.46, 2.55] | 514540 | pinned | h264_libx264:1.00, copy_passthrough:1.57, mjpeg:0.98, h265_libx265:1.00 |
| tsan-stmt-yoff | tsan-stmt-yoff | 5 | 1.105 [1.099, 1.119] | — | 2.54 [2.47, 2.56] | 514493 | pinned | h264_libx264:0.99, copy_passthrough:1.54, mjpeg:0.98, h265_libx265:1.00 |
| tsan-yoff | tsan-yoff | 5 | 0.991 [0.982, 1.002] | — | 2.83 [2.76, 2.86] | 514609 | pinned | h264_libx264:1.00, copy_passthrough:0.97, mjpeg:1.00, h265_libx265:1.00 |

#### memcached

Session: mode=pinned cpuset=4-27,60-83 governor=powersave no_turbo=0 host=focs-server started=2026-09-09T06:06:57

| config | N | ops_sec median (mean ± σ, CV) |
|---|---|---|
| orig | 5 | 5.42e+06 (5.476e+06 ± 1.9e+05, 3.5 %) |
| tsan | 5 | 1.604e+06 (1.603e+06 ± 8.5e+03, 0.5 %) |
| tsan-dom_peeling-ea-lo-st-swmr | 5 | 1.623e+06 (1.612e+06 ± 5.9e+04, 3.6 %) |
| tsan-dom_peeling-ea-lo-st-swmr-yoff | 5 | 1.63e+06 (1.615e+06 ± 2.9e+04, 1.8 %) |
| tsan-sound | 5 | 1.613e+06 (1.592e+06 ± 4.6e+04, 2.9 %) |
| tsan-sound-yoff | 5 | 1.613e+06 (1.613e+06 ± 2.8e+04, 1.8 %) |
| tsan-stmt | 5 | 1.601e+06 (1.587e+06 ± 2.6e+04, 1.7 %) |
| tsan-stmt-yoff | 5 | 1.609e+06 (1.591e+06 ± 5e+04, 3.1 %) |
| tsan-yoff | 5 | 1.636e+06 (1.621e+06 ± 2.8e+04, 1.8 %) |

##### Speedup vs stock TSan (SU) and slowdown vs native (SD), on medians; geometric mean over tests; 95 % bootstrap interval

| config | label | N | SU geomean [95 %] | SU stable [95 %] | SD geomean [95 %] | static sites | modes | per-test SU |
|---|---|---|---|---|---|---|---|---|
| orig | orig | 5 | 3.378 [3.271, 3.590] | — | — | 0 | pinned | ops_sec:3.38 |
| tsan | tsan | 5 | — | — | 3.38 [3.27, 3.59] | 6748 | pinned |  |
| tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 5 | 1.012 [0.944, 1.059] | — | 3.34 [3.13, 3.75] | 7127 | pinned | ops_sec:1.01 |
| tsan-dom_peeling-ea-lo-st-swmr-yoff | tsan-dom_peeling-ea-lo-st-swmr-yoff | 5 | 1.016 [0.978, 1.031] | — | 3.33 [3.22, 3.62] | 7130 | pinned | ops_sec:1.02 |
| tsan-sound | tsan-sound | 5 | 1.005 [0.945, 1.026] | — | 3.36 [3.23, 3.75] | 6640 | pinned | ops_sec:1.01 |
| tsan-sound-yoff | tsan-sound-yoff | 5 | 1.006 [0.970, 1.031] | — | 3.36 [3.22, 3.65] | 6643 | pinned | ops_sec:1.01 |
| tsan-stmt | tsan-stmt | 5 | 0.998 [0.956, 1.008] | — | 3.39 [3.29, 3.70] | 6810 | pinned | ops_sec:1.00 |
| tsan-stmt-yoff | tsan-stmt-yoff | 5 | 1.003 [0.943, 1.026] | — | 3.37 [3.23, 3.75] | 6810 | pinned | ops_sec:1.00 |
| tsan-yoff | tsan-yoff | 5 | 1.019 [0.983, 1.034] | — | 3.31 [3.21, 3.60] | 6748 | pinned | ops_sec:1.02 |

#### redis

Session: mode=pinned cpuset=4-27,60-83 governor=powersave no_turbo=0 host=focs-server started=2026-09-09T08:07:43

| config | N | PING_INLINE median (mean ± σ, CV) | PING_MBULK median (mean ± σ, CV) | SET median (mean ± σ, CV) | GET median (mean ± σ, CV) | INCR median (mean ± σ, CV) | RPUSH median (mean ± σ, CV) | LPOP median (mean ± σ, CV) | RPOP median (mean ± σ, CV) | SADD median (mean ± σ, CV) | HSET median (mean ± σ, CV) | SPOP median (mean ± σ, CV) | ZADD median (mean ± σ, CV) | ZPOPMIN median (mean ± σ, CV) | LPUSH median (mean ± σ, CV) | LRANGE_100 median (mean ± σ, CV) | LRANGE_300 median (mean ± σ, CV) | LRANGE_500 median (mean ± σ, CV) | LRANGE_600 median (mean ± σ, CV) | MSET median (mean ± σ, CV) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| orig | 5 | 4.117e+06 (4.141e+06 ± 2.3e+05, 5.6 %) | 6.496e+06 (6.38e+06 ± 2.4e+05, 3.8 %) | 3.107e+06 (3.084e+06 ± 7.8e+04, 2.5 %) | 3.692e+06 (3.704e+06 ± 7.7e+04, 2.1 %) | 3.761e+06 (3.817e+06 ± 2.3e+05, 6.0 %) | 2.969e+06 (2.896e+06 ± 1.1e+05, 3.8 %) | 2.817e+06 (2.785e+06 ± 1.4e+05, 5.0 %) | 4.369e+06 (4.351e+06 ± 9.1e+04, 2.1 %) | 3.413e+06 (3.398e+06 ± 6.9e+04, 2.0 %) | 2.605e+06 (2.61e+06 ± 1.3e+05, 5.0 %) | 5.078e+06 (5.118e+06 ± 1.5e+05, 3.0 %) | 2.399e+06 (2.389e+06 ± 4.2e+04, 1.8 %) | 4.953e+06 (4.954e+06 ± 9.1e+04, 1.8 %) | 2.661e+06 (2.651e+06 ± 4.6e+04, 1.7 %) | 1.382e+05 (1.37e+05 ± 5.4e+03, 3.9 %) | 3.917e+04 (3.864e+04 ± 1.6e+03, 4.1 %) | 2.339e+04 (2.344e+04 ± 3.5e+02, 1.5 %) | 1.911e+04 (1.914e+04 ± 3.5e+02, 1.8 %) | 5.422e+05 (5.32e+05 ± 3.3e+04, 6.2 %) |
| tsan | 5 | 5.376e+05 (5.378e+05 ± 1.1e+04, 2.1 %) | 7.151e+05 (7.643e+05 ± 8.5e+04, 11.1 %) | 3.345e+05 (3.383e+05 ± 1.3e+04, 3.8 %) | 4.415e+05 (4.399e+05 ± 9.3e+03, 2.1 %) | 4.351e+05 (4.322e+05 ± 7.6e+03, 1.8 %) | 2.66e+05 (2.677e+05 ± 4.6e+03, 1.7 %) | 2.402e+05 (2.403e+05 ± 6.4e+03, 2.7 %) | 4.864e+05 (4.903e+05 ± 2e+04, 4.0 %) | 3.658e+05 (3.767e+05 ± 1.8e+04, 4.8 %) | 2.814e+05 (2.819e+05 ± 7.5e+03, 2.7 %) | 5.241e+05 (5.38e+05 ± 3.1e+04, 5.8 %) | 2.968e+05 (3.007e+05 ± 1.3e+04, 4.2 %) | 5.524e+05 (5.585e+05 ± 1.2e+04, 2.1 %) | 2.32e+05 (2.307e+05 ± 4e+03, 1.8 %) | 2.484e+04 (2.491e+04 ± 2e+02, 0.8 %) | 8961 (8967 ± 35, 0.4 %) | 5482 (5397 ± 2.2e+02, 4.1 %) | 4540 (4540 ± 7.8, 0.2 %) | 6.395e+04 (6.394e+04 ± 2.7e+03, 4.2 %) |
| tsan-dom_peeling-ea-lo-st-swmr | 5 | 4.972e+05 (4.773e+05 ± 4.5e+04, 9.5 %) | 7.161e+05 (7.332e+05 ± 6.3e+04, 8.5 %) | 3.353e+05 (3.362e+05 ± 1.1e+04, 3.2 %) | 4.329e+05 (4.29e+05 ± 2.3e+04, 5.4 %) | 4.346e+05 (4.248e+05 ± 3e+04, 7.2 %) | 2.612e+05 (2.616e+05 ± 1.2e+04, 4.6 %) | 2.454e+05 (2.439e+05 ± 1.4e+04, 5.9 %) | 5.055e+05 (4.945e+05 ± 2.9e+04, 5.9 %) | 3.934e+05 (3.785e+05 ± 3e+04, 8.0 %) | 2.923e+05 (2.893e+05 ± 1.7e+04, 5.8 %) | 5.266e+05 (5.153e+05 ± 4.8e+04, 9.2 %) | 2.906e+05 (2.848e+05 ± 2.1e+04, 7.5 %) | 5.165e+05 (5.168e+05 ± 3.1e+04, 5.9 %) | 2.324e+05 (2.277e+05 ± 1.1e+04, 5.0 %) | 2.503e+04 (2.546e+04 ± 7.6e+02, 3.0 %) | 9108 (9094 ± 55, 0.6 %) | 5547 (5530 ± 52, 0.9 %) | 4592 (4582 ± 29, 0.6 %) | 6.375e+04 (6.383e+04 ± 2.3e+03, 3.7 %) |
| tsan-dom_peeling-ea-lo-st-swmr-yoff | 5 | 4.914e+05 (4.973e+05 ± 3.3e+04, 6.6 %) | 7.828e+05 (7.545e+05 ± 4.6e+04, 6.1 %) | 3.374e+05 (3.358e+05 ± 1.3e+04, 3.8 %) | 4.454e+05 (4.449e+05 ± 1.4e+04, 3.1 %) | 4.263e+05 (4.273e+05 ± 7.5e+03, 1.8 %) | 2.719e+05 (2.707e+05 ± 4e+03, 1.5 %) | 2.411e+05 (2.407e+05 ± 3.3e+03, 1.4 %) | 4.899e+05 (4.936e+05 ± 1.1e+04, 2.2 %) | 3.667e+05 (3.685e+05 ± 9.5e+03, 2.6 %) | 2.908e+05 (2.959e+05 ± 1.2e+04, 4.1 %) | 5.353e+05 (5.412e+05 ± 1.6e+04, 2.9 %) | 3.016e+05 (2.999e+05 ± 1.2e+04, 4.2 %) | 5.58e+05 (5.537e+05 ± 2.4e+04, 4.3 %) | 2.304e+05 (2.31e+05 ± 4.2e+03, 1.8 %) | 2.529e+04 (2.581e+04 ± 9.1e+02, 3.5 %) | 9124 (9125 ± 33, 0.4 %) | 5548 (5557 ± 30, 0.5 %) | 4612 (4612 ± 21, 0.5 %) | 6.584e+04 (6.48e+04 ± 2.3e+03, 3.5 %) |
| tsan-sound | 5 | 4.911e+05 (4.859e+05 ± 1.9e+04, 3.9 %) | 7.792e+05 (7.707e+05 ± 3.6e+04, 4.6 %) | 3.317e+05 (3.382e+05 ± 1.1e+04, 3.4 %) | 4.365e+05 (4.4e+05 ± 1.8e+04, 4.1 %) | 4.35e+05 (4.357e+05 ± 7.8e+03, 1.8 %) | 2.706e+05 (2.671e+05 ± 7.2e+03, 2.7 %) | 2.447e+05 (2.432e+05 ± 5.1e+03, 2.1 %) | 4.887e+05 (4.933e+05 ± 1.2e+04, 2.4 %) | 3.719e+05 (3.687e+05 ± 1.3e+04, 3.4 %) | 2.854e+05 (2.895e+05 ± 1.6e+04, 5.5 %) | 5.364e+05 (5.293e+05 ± 3.3e+04, 6.2 %) | 2.931e+05 (2.976e+05 ± 2.1e+04, 6.9 %) | 5.23e+05 (5.299e+05 ± 2.7e+04, 5.1 %) | 2.288e+05 (2.303e+05 ± 3.8e+03, 1.6 %) | 2.459e+04 (2.507e+04 ± 9.7e+02, 3.9 %) | 8831 (8836 ± 30, 0.3 %) | 5404 (5401 ± 29, 0.5 %) | 4472 (4464 ± 21, 0.5 %) | 6.258e+04 (6.304e+04 ± 3e+03, 4.7 %) |
| tsan-sound-yoff | 5 | 4.914e+05 (4.956e+05 ± 1.4e+04, 2.8 %) | 7.427e+05 (7.475e+05 ± 4.7e+04, 6.2 %) | 3.335e+05 (3.37e+05 ± 9.9e+03, 3.0 %) | 4.386e+05 (4.367e+05 ± 3.8e+03, 0.9 %) | 4.345e+05 (4.322e+05 ± 6.8e+03, 1.6 %) | 2.68e+05 (2.654e+05 ± 8.1e+03, 3.1 %) | 2.406e+05 (2.421e+05 ± 3.9e+03, 1.6 %) | 4.928e+05 (4.93e+05 ± 2.1e+04, 4.3 %) | 3.707e+05 (3.773e+05 ± 1.7e+04, 4.5 %) | 2.968e+05 (2.974e+05 ± 1.1e+04, 3.6 %) | 5.564e+05 (5.38e+05 ± 3.5e+04, 6.5 %) | 2.884e+05 (2.918e+05 ± 1.6e+04, 5.4 %) | 5.494e+05 (5.451e+05 ± 2.4e+04, 4.4 %) | 2.268e+05 (2.296e+05 ± 5.5e+03, 2.4 %) | 2.479e+04 (2.484e+04 ± 2.4e+02, 1.0 %) | 8931 (8945 ± 37, 0.4 %) | 5441 (5434 ± 24, 0.4 %) | 4518 (4524 ± 25, 0.6 %) | 6.072e+04 (6.082e+04 ± 2.6e+03, 4.2 %) |
| tsan-stmt | 5 | 4.732e+05 (4.705e+05 ± 1.6e+04, 3.3 %) | 7.444e+05 (7.372e+05 ± 2.7e+04, 3.6 %) | 3.365e+05 (3.353e+05 ± 1.1e+04, 3.3 %) | 4.205e+05 (4.21e+05 ± 1.4e+04, 3.2 %) | 4.126e+05 (4.123e+05 ± 1.8e+04, 4.4 %) | 2.594e+05 (2.59e+05 ± 3.3e+03, 1.3 %) | 2.388e+05 (2.383e+05 ± 6.8e+03, 2.8 %) | 4.987e+05 (4.928e+05 ± 1.2e+04, 2.5 %) | 3.689e+05 (3.681e+05 ± 2.2e+04, 5.9 %) | 2.823e+05 (2.806e+05 ± 1.3e+04, 4.8 %) | 5.115e+05 (5.044e+05 ± 3.5e+04, 7.0 %) | 2.711e+05 (2.762e+05 ± 1.1e+04, 4.0 %) | 5.382e+05 (5.336e+05 ± 2e+04, 3.8 %) | 2.248e+05 (2.234e+05 ± 4.8e+03, 2.1 %) | 2.436e+04 (2.462e+04 ± 7.6e+02, 3.1 %) | 8705 (8678 ± 1e+02, 1.2 %) | 5336 (5335 ± 14, 0.3 %) | 4422 (4409 ± 46, 1.0 %) | 6.365e+04 (6.326e+04 ± 1.9e+03, 3.0 %) |
| tsan-stmt-yoff | 5 | 4.69e+05 (4.645e+05 ± 1.6e+04, 3.5 %) | 7.367e+05 (7.169e+05 ± 4.5e+04, 6.2 %) | 3.391e+05 (3.357e+05 ± 7.1e+03, 2.1 %) | 4.206e+05 (4.176e+05 ± 7.1e+03, 1.7 %) | 4.136e+05 (4.164e+05 ± 1.4e+04, 3.4 %) | 2.574e+05 (2.597e+05 ± 5.7e+03, 2.2 %) | 2.347e+05 (2.355e+05 ± 5.8e+03, 2.4 %) | 4.931e+05 (4.853e+05 ± 2.4e+04, 4.9 %) | 3.681e+05 (3.688e+05 ± 1.6e+04, 4.4 %) | 2.789e+05 (2.791e+05 ± 1.1e+04, 4.1 %) | 5.128e+05 (5.209e+05 ± 2.7e+04, 5.1 %) | 2.812e+05 (2.845e+05 ± 1.1e+04, 4.0 %) | 5.282e+05 (5.253e+05 ± 2.1e+04, 4.1 %) | 2.276e+05 (2.268e+05 ± 4.3e+03, 1.9 %) | 2.378e+04 (2.4e+04 ± 7.8e+02, 3.3 %) | 8568 (8556 ± 87, 1.0 %) | 5242 (5227 ± 36, 0.7 %) | 4354 (4350 ± 24, 0.5 %) | 6.399e+04 (6.376e+04 ± 1.6e+03, 2.4 %) |
| tsan-yoff | 5 | 4.866e+05 (4.871e+05 ± 1.6e+04, 3.2 %) | 7.255e+05 (7.312e+05 ± 3.9e+04, 5.4 %) | 3.363e+05 (3.413e+05 ± 8e+03, 2.3 %) | 4.357e+05 (4.415e+05 ± 1.2e+04, 2.7 %) | 4.322e+05 (4.234e+05 ± 1.5e+04, 3.5 %) | 2.682e+05 (2.693e+05 ± 4.3e+03, 1.6 %) | 2.417e+05 (2.43e+05 ± 3.7e+03, 1.5 %) | 4.842e+05 (4.885e+05 ± 2.2e+04, 4.5 %) | 3.718e+05 (3.727e+05 ± 1.1e+04, 2.9 %) | 2.881e+05 (2.97e+05 ± 1.9e+04, 6.3 %) | 5.396e+05 (5.438e+05 ± 2.3e+04, 4.1 %) | 3.037e+05 (3.048e+05 ± 1.1e+04, 3.7 %) | 5.44e+05 (5.361e+05 ± 2.2e+04, 4.2 %) | 2.324e+05 (2.302e+05 ± 4.1e+03, 1.8 %) | 2.489e+04 (2.489e+04 ± 44, 0.2 %) | 8959 (8963 ± 43, 0.5 %) | 5474 (5480 ± 17, 0.3 %) | 4531 (4531 ± 15, 0.3 %) | 6.52e+04 (6.447e+04 ± 2.5e+03, 3.9 %) |

##### Speedup vs stock TSan (SU) and slowdown vs native (SD), on medians; geometric mean over tests; 95 % bootstrap interval

**SU stable** repeats the speedup over the 16 of 19 subtests whose pooled run-to-run CV, taken over every configuration rather than off the baseline alone, is at most 5 %. The set is a property of the workload, not of a configuration, and applies to every row alike. Excluded here: `PING_INLINE` (pooled CV 5.0 %); `PING_MBULK` (pooled CV 6.6 %); `SPOP` (pooled CV 5.9 %). Report the all-subtest column as the headline and this one as what the data can resolve.

| config | label | N | SU geomean [95 %] | SU stable [95 %] | SD geomean [95 %] | static sites | modes | per-test SU |
|---|---|---|---|---|---|---|---|---|
| orig | orig | 5 | 7.993 [7.725, 8.068] | 7.855 [7.635, 7.950] | — | 0 | pinned | PING_INLINE:7.66, PING_MBULK:9.08, SET:9.29, GET:8.36, INCR:8.64, RPUSH:11.16, LPOP:11.73, RPOP:8.98, SADD:9.33, HSET:9.26, SPOP:9.69, ZADD:8.08, ZPOPMIN:8.97, LPUSH:11.47, LRANGE_100:5.57, LRANGE_300:4.37, LRANGE_500:4.27, LRANGE_600:4.21, MSET:8.48 |
| tsan | tsan | 5 | — | — | 7.99 [7.73, 8.07] | 37941 | pinned |  |
| tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 5 | 1.001 [0.954, 1.010] | 1.006 [0.966, 1.019] | 7.98 [7.82, 8.27] | 43242 | pinned | PING_INLINE:0.92, PING_MBULK:1.00, SET:1.00, GET:0.98, INCR:1.00, RPUSH:0.98, LPOP:1.02, RPOP:1.04, SADD:1.08, HSET:1.04, SPOP:1.00, ZADD:0.98, ZPOPMIN:0.93, LPUSH:1.00, LRANGE_100:1.01, LRANGE_300:1.02, LRANGE_500:1.01, LRANGE_600:1.01, MSET:1.00 |
| tsan-dom_peeling-ea-lo-st-swmr-yoff | tsan-dom_peeling-ea-lo-st-swmr-yoff | 5 | 1.011 [0.981, 1.024] | 1.011 [0.991, 1.027] | 7.91 [7.72, 8.03] | 43291 | pinned | PING_INLINE:0.91, PING_MBULK:1.09, SET:1.01, GET:1.01, INCR:0.98, RPUSH:1.02, LPOP:1.00, RPOP:1.01, SADD:1.00, HSET:1.03, SPOP:1.02, ZADD:1.02, ZPOPMIN:1.01, LPUSH:0.99, LRANGE_100:1.02, LRANGE_300:1.02, LRANGE_500:1.01, LRANGE_600:1.02, MSET:1.03 |
| tsan-sound | tsan-sound | 5 | 0.995 [0.968, 1.013] | 0.993 [0.976, 1.015] | 8.03 [7.80, 8.14] | 37604 | pinned | PING_INLINE:0.91, PING_MBULK:1.09, SET:0.99, GET:0.99, INCR:1.00, RPUSH:1.02, LPOP:1.02, RPOP:1.00, SADD:1.02, HSET:1.01, SPOP:1.02, ZADD:0.99, ZPOPMIN:0.95, LPUSH:0.99, LRANGE_100:0.99, LRANGE_300:0.99, LRANGE_500:0.99, LRANGE_600:0.98, MSET:0.98 |
| tsan-sound-yoff | tsan-sound-yoff | 5 | 0.998 [0.970, 1.013] | 0.997 [0.978, 1.015] | 8.01 [7.80, 8.13] | 37607 | pinned | PING_INLINE:0.91, PING_MBULK:1.04, SET:1.00, GET:0.99, INCR:1.00, RPUSH:1.01, LPOP:1.00, RPOP:1.01, SADD:1.01, HSET:1.05, SPOP:1.06, ZADD:0.97, ZPOPMIN:0.99, LPUSH:0.98, LRANGE_100:1.00, LRANGE_300:1.00, LRANGE_500:0.99, LRANGE_600:1.00, MSET:0.95 |
| tsan-stmt | tsan-stmt | 5 | 0.976 [0.945, 0.987] | 0.979 [0.955, 0.993] | 8.19 [8.01, 8.35] | 37878 | pinned | PING_INLINE:0.88, PING_MBULK:1.04, SET:1.01, GET:0.95, INCR:0.95, RPUSH:0.98, LPOP:0.99, RPOP:1.03, SADD:1.01, HSET:1.00, SPOP:0.98, ZADD:0.91, ZPOPMIN:0.97, LPUSH:0.97, LRANGE_100:0.98, LRANGE_300:0.97, LRANGE_500:0.97, LRANGE_600:0.97, MSET:1.00 |
| tsan-stmt-yoff | tsan-stmt-yoff | 5 | 0.971 [0.942, 0.982] | 0.974 [0.954, 0.988] | 8.23 [8.04, 8.38] | 37882 | pinned | PING_INLINE:0.87, PING_MBULK:1.03, SET:1.01, GET:0.95, INCR:0.95, RPUSH:0.97, LPOP:0.98, RPOP:1.01, SADD:1.01, HSET:0.99, SPOP:0.98, ZADD:0.95, ZPOPMIN:0.96, LPUSH:0.98, LRANGE_100:0.96, LRANGE_300:0.96, LRANGE_500:0.96, LRANGE_600:0.96, MSET:1.00 |
| tsan-yoff | tsan-yoff | 5 | 1.000 [0.975, 1.016] | 1.004 [0.985, 1.022] | 7.99 [7.78, 8.10] | 37941 | pinned | PING_INLINE:0.91, PING_MBULK:1.01, SET:1.01, GET:0.99, INCR:0.99, RPUSH:1.01, LPOP:1.01, RPOP:1.00, SADD:1.02, HSET:1.02, SPOP:1.03, ZADD:1.02, ZPOPMIN:0.98, LPUSH:1.00, LRANGE_100:1.00, LRANGE_300:1.00, LRANGE_500:1.00, LRANGE_600:1.00, MSET:1.02 |

#### sqlite

Session: mode=pinned cpuset=4-27,60-83 governor=powersave no_turbo=0 host=focs-server started=2026-09-09T10:37:45

| config | N | walthread1 median (mean ± σ, CV) | walthread2 median (mean ± σ, CV) | dynamic_triggers median (mean ± σ, CV) | checkpoint_starvation_1 median (mean ± σ, CV) | checkpoint_starvation_2 median (mean ± σ, CV) | stress1 median (mean ± σ, CV) | stress2 median (mean ± σ, CV) |
|---|---|---|---|---|---|---|---|---|
| orig | 5 | 5052 (5026 ± 1.2e+02, 2.3 %) | 1.554e+04 (1.581e+04 ± 6.3e+02, 4.0 %) | 5.254e+05 (5.374e+05 ± 9.8e+04, 18.3 %) | 7.93e+05 (8.132e+05 ± 9.6e+04, 11.9 %) | 782 (782 ± 0, 0.0 %) | 2.745e+05 (2.791e+05 ± 4e+04, 14.2 %) | 1.589e+05 (1.584e+05 ± 6.1e+03, 3.9 %) |
| tsan | 5 | 2761 (2760 ± 22, 0.8 %) | 6321 (6402 ± 1.7e+02, 2.6 %) | 1.17e+05 (1.227e+05 ± 2.5e+04, 20.6 %) | 1.451e+05 (1.482e+05 ± 9.8e+03, 6.6 %) | 766 (766 ± 0, 0.0 %) | 1.327e+05 (1.265e+05 ± 1.6e+04, 12.6 %) | 2.949e+04 (2.935e+04 ± 1.1e+03, 3.7 %) |
| tsan-dom_peeling-ea-lo-st-swmr | 5 | 2738 (2735 ± 12, 0.4 %) | 6222 (6264 ± 1.1e+02, 1.8 %) | 1.092e+05 (1.247e+05 ± 3.1e+04, 25.2 %) | 1.458e+05 (1.447e+05 ± 6.2e+03, 4.3 %) | 782 (775.6 ± 8.8, 1.1 %) | 1.304e+05 (1.277e+05 ± 1.2e+04, 9.1 %) | 2.978e+04 (2.97e+04 ± 5.2e+02, 1.8 %) |
| tsan-dom_peeling-ea-lo-st-swmr-yoff | 5 | 2729 (2731 ± 22, 0.8 %) | 6191 (6210 ± 76, 1.2 %) | 1.262e+05 (1.185e+05 ± 1.8e+04, 15.0 %) | 1.454e+05 (1.453e+05 ± 8.8e+03, 6.1 %) | 766 (766 ± 0, 0.0 %) | 1.218e+05 (1.234e+05 ± 4.1e+03, 3.4 %) | 2.878e+04 (2.893e+04 ± 7.6e+02, 2.6 %) |
| tsan-sound | 5 | 2689 (2712 ± 54, 2.0 %) | 6201 (6273 ± 2.2e+02, 3.5 %) | 1.05e+05 (1.114e+05 ± 1.2e+04, 10.6 %) | 1.453e+05 (1.475e+05 ± 1.1e+04, 7.7 %) | 766 (766 ± 0, 0.0 %) | 1.198e+05 (1.19e+05 ± 6.4e+03, 5.4 %) | 2.881e+04 (2.886e+04 ± 9.3e+02, 3.2 %) |
| tsan-sound-yoff | 5 | 2751 (2748 ± 49, 1.8 %) | 6265 (6256 ± 2.5e+02, 3.9 %) | 1.352e+05 (1.244e+05 ± 2.8e+04, 22.4 %) | 1.412e+05 (1.408e+05 ± 6.6e+03, 4.7 %) | 766 (769.4 ± 7.1, 0.9 %) | 1.264e+05 (1.297e+05 ± 1.1e+04, 8.4 %) | 2.941e+04 (2.906e+04 ± 8e+02, 2.8 %) |
| tsan-stmt | 5 | 2683 (2688 ± 24, 0.9 %) | 6201 (6204 ± 2.5e+02, 4.1 %) | 1.322e+05 (1.308e+05 ± 1.5e+04, 11.1 %) | 1.421e+05 (1.446e+05 ± 1.3e+04, 8.8 %) | 766 (766 ± 0, 0.0 %) | 1.417e+05 (1.328e+05 ± 1.8e+04, 13.4 %) | 2.849e+04 (2.873e+04 ± 8.2e+02, 2.9 %) |
| tsan-stmt-yoff | 5 | 2695 (2694 ± 40, 1.5 %) | 6174 (6222 ± 2.1e+02, 3.3 %) | 1.45e+05 (1.364e+05 ± 2.2e+04, 16.3 %) | 1.44e+05 (1.479e+05 ± 1.1e+04, 7.4 %) | 766 (766 ± 0, 0.0 %) | 1.243e+05 (1.221e+05 ± 1.4e+04, 11.7 %) | 2.764e+04 (2.786e+04 ± 8.7e+02, 3.1 %) |
| tsan-yoff | 5 | 2745 (2757 ± 36, 1.3 %) | 6348 (6450 ± 1.6e+02, 2.5 %) | 1.336e+05 (1.274e+05 ± 2e+04, 15.5 %) | 1.466e+05 (1.482e+05 ± 9.6e+03, 6.5 %) | 766 (769.2 ± 7.2, 0.9 %) | 1.259e+05 (1.297e+05 ± 1.2e+04, 9.4 %) | 2.996e+04 (2.958e+04 ± 8.5e+02, 2.9 %) |

##### Speedup vs stock TSan (SU) and slowdown vs native (SD), on medians; geometric mean over tests; 95 % bootstrap interval

**SU stable** repeats the speedup over the 4 of 7 subtests whose pooled run-to-run CV, taken over every configuration rather than off the baseline alone, is at most 5 %. The set is a property of the workload, not of a configuration, and applies to every row alike. Excluded here: `dynamic_triggers` (pooled CV 17.8 %); `checkpoint_starvation_1` (pooled CV 7.4 %); `stress1` (pooled CV 10.3 %). Report the all-subtest column as the headline and this one as what the data can resolve.

| config | label | N | SU geomean [95 %] | SU stable [95 %] | SD geomean [95 %] | static sites | modes | per-test SU |
|---|---|---|---|---|---|---|---|---|
| orig | orig | 5 | 2.772 [2.540, 3.052] | 2.230 [2.161, 2.310] | — | 0 | pinned | walthread1:1.83, walthread2:2.46, dynamic_triggers:4.49, checkpoint_starvation_1:5.46, checkpoint_starvation_2:1.02, stress1:2.07, stress2:5.39 |
| tsan | tsan | 5 | — | — | 2.77 [2.54, 3.05] | 57996 | pinned |  |
| tsan-dom_peeling-ea-lo-st-swmr | AllOpt+peel | 5 | 0.989 [0.918, 1.101] | 1.002 [0.976, 1.024] | 2.80 [2.53, 3.04] | 61872 | pinned | walthread1:0.99, walthread2:0.98, dynamic_triggers:0.93, checkpoint_starvation_1:1.00, checkpoint_starvation_2:1.02, stress1:0.98, stress2:1.01 |
| tsan-dom_peeling-ea-lo-st-swmr-yoff | tsan-dom_peeling-ea-lo-st-swmr-yoff | 5 | 0.991 [0.908, 1.057] | 0.986 [0.964, 1.012] | 2.80 [2.63, 3.09] | 61931 | pinned | walthread1:0.99, walthread2:0.98, dynamic_triggers:1.08, checkpoint_starvation_1:1.00, checkpoint_starvation_2:1.00, stress1:0.92, stress2:0.98 |
| tsan-sound | tsan-sound | 5 | 0.961 [0.905, 1.046] | 0.983 [0.958, 1.018] | 2.88 [2.66, 3.09] | 57006 | pinned | walthread1:0.97, walthread2:0.98, dynamic_triggers:0.90, checkpoint_starvation_1:1.00, checkpoint_starvation_2:1.00, stress1:0.90, stress2:0.98 |
| tsan-sound-yoff | tsan-sound-yoff | 5 | 1.008 [0.907, 1.083] | 0.996 [0.963, 1.023] | 2.75 [2.56, 3.08] | 57025 | pinned | walthread1:1.00, walthread2:0.99, dynamic_triggers:1.16, checkpoint_starvation_1:0.97, checkpoint_starvation_2:1.00, stress1:0.95, stress2:1.00 |
| tsan-stmt | tsan-stmt | 5 | 1.012 [0.921, 1.087] | 0.980 [0.952, 1.010] | 2.74 [2.56, 3.04] | 57961 | pinned | walthread1:0.97, walthread2:0.98, dynamic_triggers:1.13, checkpoint_starvation_1:0.98, checkpoint_starvation_2:1.00, stress1:1.07, stress2:0.97 |
| tsan-stmt-yoff | tsan-stmt-yoff | 5 | 1.004 [0.911, 1.075] | 0.972 [0.947, 1.002] | 2.76 [2.57, 3.05] | 57957 | pinned | walthread1:0.98, walthread2:0.98, dynamic_triggers:1.24, checkpoint_starvation_1:0.99, checkpoint_starvation_2:1.00, stress1:0.94, stress2:0.94 |
| tsan-yoff | tsan-yoff | 5 | 1.015 [0.934, 1.095] | 1.004 [0.978, 1.034] | 2.73 [2.54, 3.01] | 57996 | pinned | walthread1:0.99, walthread2:1.00, dynamic_triggers:1.14, checkpoint_starvation_1:1.01, checkpoint_starvation_2:1.00, stress1:0.95, stress2:1.02 |

<!-- P5-TABLES-END -->
