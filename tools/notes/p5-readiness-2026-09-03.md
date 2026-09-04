# P5 (performance re-measurement) readiness audit — 2026-09-03

Compiler: `/extra/alexey/builds/tsan-dev-3d70ff61f640` (complete: clang/clang++, lld, llvm-ar/ranlib/nm/objdump, opt,
llvm-link, TSan runtime; all analysis flags incl. `-tsan-summary-dir/-id`, `-tsan-whole-program`). Machine idle,
112 cores, 215 GB free RAM; `/` 104 GB free (93 %), `/extra` 5.3 TB. Every existing build is from another compiler
(b4bf8b8f4613 or the March paper compiler) → full rebuild needed anyway.

## Per application

| app | build configs | build size/time (×12) | bench N today | parser stats | WP summaries | blockers |
|---|---|---|---|---|---|---|
| memcached | all (composed) | 0.4 GB / 15 min | memtier `-x 5` (**25 for `tsan` only**, run-bench.sh:8-10) | memtier mean only | new interface ✓ | results overwritten; `build_memcached_all.sh` uses `tsan-all` names, `memcached_bench_all.sh:24` looks for a dir no builder makes |
| Redis | all (tokens, no `tsan-` prefix) | 0.5 GB / 35 min | **1** run/test (`orig` 10× requests, redis.sh:619) | single value, geomean over tests | legacy interface (gen_summaries.sh:82, redis.sh:466) | results truncated per run; default `BUILD_OPTIONS` not the paper set |
| SQLite | all (root config) | 0.1 GB / 3.5 h (1000 s per compile) | **1** run (log overwritten) | single log; `parse_results.py:14` expects `tsan.txt` vs `tsan.log` | **none** | stale `tsan-logs/` in the run cwd; AllOpt−peel missing from `build_sqlite_test_all.sh:27` |
| MySQL | **`tsan-dompeeling` drift** (config_definitions.sh:18 vs build_mysql_all_bases.sh:52 → abort) | 19 GB / 10–14 h (47 min per config at -j98) | **1** run × 5 scripts × 180 s | single run; "SD/SU" are ratios, not σ | legacy interface; no generator | `build_mysql.sh:179` `rm -rf`s old builds (no archiving); datadir/socket shared |
| FFmpeg | all | 11 GB / 6.5 h | `RUNS_COUNT=1` (edit in file, bench_ffmpeg_all.sh:16) | mean/σ per codec, geomean | legacy interface; no generator | `make install` over a prefix with build_info (mixes hashes); `TSAN_OPTIONS` unset in bench (report_bugs=1); AllOpt−peel missing from all-bases |
| Chromium | 7 GN configs; no `orig`/`tsan-sound`/`-stmt`; checked-in `tsan-all` lacks peeling | 47 GB per build | Telemetry repeats only | mean of `avg` | n/a | compiler path = paper compiler (e90a3fc41004); not realistic in the window |

Cross-cutting: no cross-app driver; no benchmark script records the binary/compiler hash; no parser computes
medians/variance across repetitions; result paths lack a run index everywhere except FFmpeg's internal loop.

## Time budget (12 configs, N = 5)
Builds ≈ 1.5 days (MySQL 10–14 h, FFmpeg 6.5 h, SQLite 3.5 h, Redis/memcached < 1 h; CPU-bound, not to overlap
with benches). Benches ≈ 1.5 days (MySQL ~17 h, Redis ~5 h, SQLite ~4.5 h, FFmpeg ~2 h, memcached ~1.5 h; one server
port each → serial per app, apps can overlap if CPU allows, but interference must be avoided for timing).

## Work needed before a clean run
1. A P5 driver (`tools/perf/`): per app build the configuration list from the frozen copy (tagged, archive by hash),
   run N repetitions with the run index in the result path, record compiler/binary hash per result, and one
   aggregator: median, mean ± σ, speedup vs `tsan` (and slowdown vs `orig`) with CIs, geomean where the paper uses it.
2. Fix MySQL naming (`tsan-dompeeling` → `tsan-dom_peeling`, dirs renamed), add old-builds archiving to
   `build_mysql.sh`; FFmpeg prefix archiving by hash; set `TSAN_OPTIONS=report_bugs=0` in the FFmpeg bench.
3. Equalise N: memcached `tsan` ×5 rule, Redis `orig` ×10 requests.
4. Whole-program rows: Redis `gen_summaries.sh` → new interface; SQLite: add a generator (sqlite3.c + threadtest3.c
   linked, trivial) and `USE_SUMMARIES` plumbing; MySQL/FFmpeg: linked-IR generation is new work (hundreds/thousands
   of TUs) — decide whether the WP row is per-unit-only for them.
5. Decide the configuration set (12 + WP rows? `-stmt` variants?), N (5 or 10), Chromium (separate decision).
