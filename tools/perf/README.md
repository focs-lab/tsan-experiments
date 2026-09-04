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
  sweep, never averaged.
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

_(Stage A tables are appended here as each application completes.)_
