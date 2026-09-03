# P2 — benchmark-level race-report preservation

`run_preservation.py` runs an application N times per build configuration with TSan reporting on
(`TSAN_OPTIONS="log_path=<out>/logs/<app>.<cfg>.<run> exitcode=0 external_symbolizer_path=…"`, no
suppressions, no `report_bugs=0`) and `tsan_reports.py aggregate` parses every report into two keys:
**L1** = kind + ordered pair of top frames as `function@file:line` + location descriptor (global name,
heap allocation frame, or mapped file + offset); **L2** = the same with frames by function only (allows a
relocated line inside the function, which is the only relocation the DE can cause). Per configuration it
reports reports/run (mean ± σ), distinct races per run, the union over runs, per-race detection
frequency, and the set of baseline races the configuration never reports (lost) at L1/L2.

    ./run_preservation.py --app sqlite --configs tsan --runs 10 --out results/sqlite/<tag>/tsan
    ./run_preservation.py --app sqlite --configs tsan-dom_peeling-ea-lo-st-swmr --runs 10 \
        --build-root ../../sql/sqlite/build/paper-compiler --llvm-root /extra/alexey/llvm-project-paper/llvm/build \
        --out results/sqlite/<tag>/tsan-dom_peeling-ea-lo-st-swmr
    ./tsan_reports.py aggregate --results-dir results/sqlite/<tag> --baseline tsan   # -> preservation_sqlite.md

`--out` and `--build-root` are resolved to absolute paths (a relative `--out` once made `log_path`
relative to the per-run scratch cwd, which the runner deletes — the `*.LOST-relative-out` directories
are the timings-only remains of that mistake). Every `<out>/manifest.json` records compiler tree, HEAD,
binary hashes and workload parameters; `runs.jsonl` has one line per run with wall-clock seconds.

## SQLite `threadtest3` (paper workload), N = 10, 2026-09-02

Five runners concurrently on the same machine (timings therefore only indicative).
Compilers: tsan-dev 89e5d0078d2f (`results/sqlite/2026-09-02-hardened-0de7a735/`) and the paper
compiler e90a3fc41004 (`results/sqlite/2026-09-02-paper-e90a3fc4/`).

| compiler | config | reports/run | distinct L1/run | union L1 | union L2 | lost vs stock L1 / L2 | median s |
|---|---|---|---|---|---|---|---|
| tsan-dev | `tsan` | 2.2 ± 1.5 | 2.2 ± 1.5 | 5 | 2 | — | 281 |
| tsan-dev | `tsan-sound` (EA+LO+ST+SWMR) | 1.8 ± 1.5 | 1.8 ± 1.5 | 5 | 2 | 0 / 0 | 281 |
| tsan-dev | AllOpt (sound + DE + peeling) | 1.8 ± 2.1 | 1.6 ± 1.6 | 5 | 2 | 0 / 0 | 295 |
| paper | `tsan` | 2.9 ± 1.4 | 2.7 ± 1.2 | 5 | 2 | — | 284 |
| paper | AllOpt | **0.1 ± 0.3** | 0.1 ± 0.3 | **1** | **1** | **4 of 5 / 1 of 2** | 345 |

All reports are the two known wal-index families (TSan sees SQLite's own memory-barrier discipline as
races): (a) `walTryBeginRead:69040` atomic read of `aReadMark[i]` vs `walRestartHdr:68034/68035` stores
(four L1 entries, one per read-mark offset in `test.db-shm`), (b) `walTryBeginRead:68991` vs
`walIndexRecover:67450`. Detection is stochastic per run for every build (stock 2–9 of 10 per entry).

Per-race detection frequency (of 10 runs):

| race (L1) | dev stock | dev sound | dev AllOpt | paper stock | paper AllOpt |
|---|---|---|---|---|---|
| 68991 / walIndexRecover:67450, shm+0x60 | 4 | 5 | 3 | 5 | 1 |
| 69040 / walRestartHdr:68034, shm+0x68 | 7 | 3 | 4 | 9 | 0 |
| 69040 / walRestartHdr:68035, shm+0x6c | 2 | 4 | 2 | 2 | 0 |
| 69040 / walRestartHdr:68035, shm+0x70 | 6 | 5 | 6 | 9 | 0 |
| 69040 / walRestartHdr:68035, shm+0x74 | 3 | 1 | 1 | 2 | 0 |

Why the paper's AllOpt loses family (a): in `walRestartHdr` the store `pInfo->nBackfillAttempted = 0`
(line 68033) dominates `pInfo->aReadMark[1] = 0` (68034) and the loop `pInfo->aReadMark[i] = READMARK_NOT_USED`
(68035); the paper's DE treated them as the same location (same underlying object `pInfo`) and removed
their instrumentation — `objdump -dl` of the paper `tsan-dom`/AllOpt binaries shows `__tsan_write4` only
for lines 66700, 68027 and 68033 in that function, against 68027/28/30/33/34/35 (and the inlined
`sqlite3Put4byte`) in stock, tsan-dev AllOpt and the paper+must-alias diagnostic build. This is the
`tools/de-yield` defect 1 observed on a real race. Family (b) survives at 1/10 because its reported
write (`pInfo->nBackfill = 0`, 67450) is the *first* store to the object and stays instrumented; the
following `nBackfillAttempted`/`aReadMark[0]` stores (67451–67452) are elided.

## FFmpeg (paper workload: libx264, libx265, mjpeg, stream copy on `WatchingEyeTexture.mkv`, `-threads 4`), N = 10, submitted binaries, 2026-09-02

`results/ffmpeg/2026-09-02-paper-march6/`: stock and AllOpt (`ffmpeg-tsan`, `ffmpeg-tsan-dom_peeling-ea-lo-st-swmr`,
both built 2026-03-06 with focs-lab c35c3bd998f1, i.e. the binaries behind the paper's FFmpeg numbers).
**0 reports in all 80 process logs** (10 runs × 4 encoder invocations × 2 configs, every exit code 0).
FFmpeg's worker threads are TSan-clean under this workload, so — like Redis — FFmpeg cannot serve as
preservation evidence; it only shows that the optimized build reports nothing new. Median wall-clock per run
(4 encodes): stock 180 s, AllOpt 144 s (machine shared with the memcached run; indicative only).

## memcached 1.6.29 (paper workload: memtier_benchmark -t 10 -x 25 --pipeline 16, server `-t nproc`), N = 10, submitted binaries, 2026-09-02

`results/memcached/2026-09-02-paper-march6/`: stock (`old-builds/memcached-tsan.20260306`, focs-lab c35c3bd998f1,
2026-03-03) vs the paper's AllOpt `memcached-tsan-all` (9f5d402cb36b, 2026-03-06), via `paper-builds/` symlinks.

| config | reports/run | distinct L1/run | union L1 | union L2 | lost vs stock L1 / L2 | new L1 / L2 |
|---|---|---|---|---|---|---|
| stock | 11.8 ± 3.6 | 10.8 ± 3.6 | 17 | 17 | — | — |
| AllOpt (submitted) | 14.5 ± 8.3 | 9.4 ± 8.0 | 37 | 21 | 1 / 1 | 21 / 5 |

memcached is the richest corpus so far: 17 stock L1 sites, 7 of them in 10/10 runs (`stats_state` read in
`clock_handler` vs `do_item_link`/`do_item_unlink`; `current_time` written by `clock_handler` vs readers in
`do_item_link`, `try_read_command_ascii`, `lru_maintainer_thread`; `do_item_unlink` vs `item_remove`/`lru_pull_tail`
on slab memory). Against the submitted AllOpt: one stock site lost at L1 and L2
(`conn_release_items:840` vs `conn_new:766`, 3/10 in stock, 0/10); the two `stats_state` sites drop from 10/10
to 1/10 (not counted as lost by the set difference, but a 10× frequency drop); 21 new L1 sites, almost all
`conn_new`-vs-`conn_new` write/write pairs on a connection object reported in a single run — a burst of reports
from one run, i.e. the optimized binary changes which interleaving TSan happens to catch, in both directions.
Submitted-binary rows are provenance only (the response reports the current compiler).

## Final tsan-dev compiler b4bf8b8f4613 (2026-09-02 evening): SQLite, FFmpeg, memcached, N = 10

Builds of 21:13–21:16 (`build_info.txt` in each build dir; per-TU analyses, no whole-program summaries).
Configurations: `tsan` = stock; `tsan-sound` = `-tsan-use-escape-analysis-global -tsan-use-lock-ownership
-tsan-use-single-threaded -tsan-use-swmr`; **AllOpt+peel** (the paper's AllOpt) = tsan-sound +
`-tsan-use-dominance-analysis -tsan-use-loop-peeling=true` (dir suffix `dom_peeling-ea-lo-st-swmr`; memcached `tsan-all`).
Results dirs `results/<app>/2026-09-02-final-b4bf8b8f4613/`.

**SQLite threadtest3** (three runners in parallel, median 258 / 267 / 276 s per run):

| config | reports/run | distinct L1/run | union L1 | union L2 | lost vs stock L1 / L2 | new L1 / L2 | relocated |
|---|---|---|---|---|---|---|---|
| stock | 4.7 ± 1.1 | 4.4 ± 0.7 | 5 | 2 | — | — | — |
| tsan-sound | 4.7 ± 0.8 | 4.3 ± 0.5 | 5 | 2 | 0 / 0 | 0 / 0 | 0 |
| AllOpt+peel | 4.8 ± 0.8 | 4.4 ± 0.5 | 6 | 2 | 0 / 0 | 1 / 0 | 0 |

Same two wal-index families as before; four of the five stock sites are now found in 10/10 runs by every
configuration (the runtime of this compiler reports more consistently than the 07:07 build did). The one new
AllOpt+peel L1 site (`walTryBeginRead:69040` vs `walIndexRecover:67459`, 1/10) is a third write site of family (b)
on the same mapped word; L2 union unchanged.

**FFmpeg** (4 encoder threads, 4 encodes per run, three runners in parallel): 0 reports in all 30 runs of
all three configurations (every ffmpeg exit code 0). FFmpeg is TSan-clean under the paper's workload;
preservation is trivially satisfied and the app carries no evidence weight.

**memcached** (memtier -t 10 -x 25 --pipeline 16, server `-t nproc`, one sequential runner; median 125 / 111 / 104 s per run):

| config | reports/run | distinct L1/run | union L1 | union L2 | lost vs stock L1 / L2 | new L1 / L2 | relocated |
|---|---|---|---|---|---|---|---|
| stock | 9.7 ± 2.3 | 8.7 ± 2.3 | 16 | 16 | — | — | — |
| tsan-sound | 7.2 ± 2.1 | 6.2 ± 2.1 | 13 | 13 | **4 / 4** | 1 / 1 | 0 |
| AllOpt+peel | 11.1 ± 2.1 | 6.1 ± 2.1 | 13 | 13 | **4 / 4** | 1 / 1 | 0 |

**Not preserved.** The four lost sites are reads of the global `current_time` (written once a second by
`clock_handler` on the main thread, read unsynchronised by worker threads): `do_item_link@items.c:495`
(`it->time = current_time`), `lru_maintainer_thread@items.c:1671`, `try_read_command_ascii@proto_text.c:493`
— each 10/10 in stock and 0/10 in both optimized builds — and `lru_maintainer_juggle@items.c:1426` (1/10 stock).
`objdump -dl` shows their `__tsan_read4` calls elided in `memcached-tsan-sound` and `memcached-tsan-all` (the
adjacent `__tsan_write4` on the same lines is kept); single-analysis builds on the same hash
(`memcached-tsan-{swmr,st,ea,lo}.bisect-b4bf8b8f`) attribute the elision to **SWMR alone**. The one new site
(`conn_new@memcached.c:761` reading `current_time`, 10/10 optimized, 0/10 stock) is the reader that is still
instrumented winning the report on that granule. 12 of 16 stock sites are preserved, 7 of them at 10/10 in every
configuration. Reported to tsan-dev 2026-09-02 22:40; to be re-measured after the SWMR fix.

## tsan-audit def2cf34faeb (2026-09-03 01:35–02:40): memcached and SQLite re-run after the SWMR fix

Frozen compiler `/extra/alexey/builds/tsan-audit-def2cf34faeb` (= b4bf8b8f4613 + SWMR-1 "a global is SWMR
read-only only if it has local linkage and a definition in the unit" + the `-tsan-ea-flow-insensitive` cache fix).
Builds 01:35 (`build_info.txt`), N = 10, same configurations and criterion as above. Static sites: memcached
6526 / sound 5150 / AllOpt+peel 5632 (was 4746 / 5182 on b4bf8b8f4613); SQLite 55531 / 46780 / 50805.

**memcached** (`results/memcached/2026-09-03-final-def2cf34faeb/`):

| config | reports/run | distinct L1/run | union L1 | union L2 | lost vs stock L1 / L2 | new | relocated |
|---|---|---|---|---|---|---|---|
| stock | 10.4 ± 3.2 | 9.4 ± 3.2 | 17 | 17 | — | — | — |
| tsan-sound | 9.7 ± 2.3 | 8.7 ± 2.3 | 17 | 17 | **0 / 0** | 0 | 0 |
| AllOpt+peel | 13.2 ± 1.0 | 8.1 ± 0.9 | 10 | 10 | 7 / 7 | 0 | 0 |

The SWMR fix restores the four `current_time` readers (`do_item_link:495`, `lru_maintainer_thread:1671`,
`try_read_command_ascii:493` at 10/10 in every configuration, `lru_maintainer_juggle:1426` 1/10 everywhere), and the
`conn_new:761` relocation is gone. **tsan-sound now reports exactly the stock set** (17/17 at L1, no relocation).
AllOpt+peel "loses" 7 sites by the set-difference rule: all seven are one family — reads/writes of a freshly
allocated `conn` object in `conn_new` vs `rbuf_release` / `drive_machine` / `conn_close` / `conn_set_state` /
`try_read_network` / `conn_release_items` — that stock reported in 2 of 10 runs (the same two runs), and the
optimized runs 0 of 10. Every access of that family is still instrumented in the AllOpt+peel binary (checked
line by line with `objdump -dl`), so this is not an elision; a family seen in 2/10 baseline runs has an ~11 %
chance of being absent from 10 runs by luck, and N = 10 cannot resolve it. The 10 sites reported in ≥ 8/10 stock
runs are all reported at the same frequency by AllOpt+peel.

*Extended to N = 30 for stock and AllOpt+peel (runs 11–30 added 03:00–04:30; tsan-sound stays at N = 10):*

| config | runs | reports/run | union L1 | union L2 | lost vs stock (N=30) L1 / L2 | new L1 / L2 |
|---|---|---|---|---|---|---|
| stock | 30 | 11.6 ± 5.7 | 34 | 21 | — | — |
| AllOpt+peel | 30 | 15.8 ± 8.0 | 51 | 24 | 1 (relocated, found at L2) / 0 | 18 / 3 |

At N = 30 the `conn_new` family appears in both builds: its six core sites are at 6–7/30 in stock and 3–5/30 in
AllOpt+peel, so the N = 10 "lost 7" was the noise floor, as predicted. The only L1-lost site is found at L2
(a `conn_new:694` self-pair, 1/30); the 18 "new" L1 sites are 1/30 `conn_new` self-pairs on the same connection
object (write/write pairs of one line with itself, a report burst in one run), all of one L2 family. The eight
sites that stock reports in ≥ 24/30 runs are reported at the same frequency by AllOpt+peel (30/30 ×7, 23–24/30 ×1).
(The tsan-sound row must be compared with stock at equal N: at N = 10 it is 17/17 with nothing lost; against the
30-run stock union it trivially "misses" the rare family sites that need more than 10 runs to appear.)

**SQLite threadtest3** (`results/sqlite/2026-09-03-final-def2cf34faeb/`):

| config | reports/run | union L1 | union L2 | lost vs stock L1 / L2 | new | relocated |
|---|---|---|---|---|---|---|
| stock | 4.6 ± 0.5 | 6 | 3 | — | — | — |
| tsan-sound | 4.1 ± 0.6 | 5 | 2 | 1 / 1 | 0 | 0 |
| AllOpt+peel | 4.4 ± 1.3 | 5 | 2 | 1 / 1 | 0 | 0 |

The five wal-index sites are preserved (four of them at 9–10/10 in every configuration). The "lost" site is a
new 1/10 stock report (`sqlite3BtreeSchema` write at 82865 vs a read of the same schema object, heap-allocated by
`sqlite3MemMalloc`) that the optimized runs did not hit; its accesses are instrumented in all three binaries. The
fifth wal-index site (`walTryBeginRead:68991` vs `walIndexRecover:67450`) again shows a lower frequency in the
optimized builds (6/10 stock vs 2/10 sound and AllOpt+peel; 7/10 vs 3/10 on b4bf8b8f4613) although both accesses
are instrumented everywhere — consistent with the schedule/eviction effect of section P4, not with elision.
Across the two rounds the site stands at 13/20 (stock) vs 5/20 (sound) and 5/20 (AllOpt+peel): a real frequency
shift with all accesses instrumented. Per-run logs are kept under `results/sqlite/2026-09-0{2,3}-final-*/`; this
site is the first candidate for the runtime eviction counters (plan P3) once they exist.

## tsan-audit 297881ddc1c5 (2026-09-03 03:14–): all twelve confirmed lost-race shapes closed; new stock baseline

Frozen `/extra/alexey/builds/tsan-audit-297881ddc1c5` (EA chain, STC/LO/SWMR per-TU-sound defaults, DE fix, plus the
upstream capture-tracking fix that raises *stock* itself). Tagged build dirs (`sql/sqlite/build/297881ddc1c5/`,
`nosql/memcached/memcached-<cfg>.297881ddc1c5`). Static memory-access sites (this hash / b4bf8b8f4613):
threadtest3 stock 57996 / 55531, sound 56420 (−2.7 %) / 46738, AllOpt+peel 61322 (+5.7 %) / 50761;
memcached stock 6748 / 6526, sound 5983 (−11.3 %) / 4746, AllOpt+peel 6491 (−3.8 %) / 5182.
Two baselines: `tsan` = stock of this hash; `tsan-old` = the b4bf8b8f4613 stock runs of 2026-09-02 (linked in).

**SQLite threadtest3**, N = 10 (`results/sqlite/2026-09-03-final-297881ddc1c5/`):

| config | reports/run | union L1 | union L2 | lost vs stock L1 / L2 | vs old stock L1 / L2 | new | relocated |
|---|---|---|---|---|---|---|---|
| stock (this hash) | 4.3 ± 1.1 | 5 | 2 | — | 0 / 0 | 0 | — |
| tsan-sound | 4.6 ± 0.5 | 5 | 2 | 0 / 0 | 0 / 0 | 0 | 0 |
| AllOpt+peel | 4.5 ± 0.8 | 5 | 2 | 0 / 0 | 0 / 0 | 0 | 0 |
| old stock (b4bf8b8f4613) | 4.7 ± 1.1 | 5 | 2 | — | — | — | — |

Both configurations report exactly the stock set against either baseline. The fifth wal-index site
(`walTryBeginRead:68991` vs `walIndexRecover:67450`) this time is 3/10 in stock and 6/10 in sound, 3/10 in
AllOpt+peel (7/10 in the old stock) — the earlier "lower in the optimized builds" pattern does not repeat, which
settles it as schedule/eviction noise rather than a systematic effect.

**memcached**, N = 10 (`results/memcached/2026-09-03-final-297881ddc1c5/`; old stock = b4bf8b8f4613 runs linked as `tsan-old`):

| config | reports/run | union L1 | union L2 | lost vs stock (this hash) L1 / L2 | new L1 / L2 | relocated |
|---|---|---|---|---|---|---|
| stock (this hash) | 15.4 ± 7.0 | 35 | 20 | — | — | — |
| tsan-sound | 17.5 ± 10.9 | 50 | 24 | 2 / **0** | 17 / 4 | 2 |
| AllOpt+peel | 17.5 ± 9.3 | 31 | 20 | 7 / **2** | 3 / 2 | 5 |
| old stock (b4bf8b8f4613) | 9.7 ± 2.3 | 16 | 16 | 19 / 4 (vs this stock) | 0 | 1 |

Stock on this hash hit the `conn_new` burst family in one run (hence union 35 vs 16–17 before), and reports
`conn_new:761` reading `current_time` in 10/10 runs (0/10 with the old stock and 0/30 on def2cf34faeb). Sound-only
loses nothing at L2; its 2 L1 "losses" are relocated (found at L2) and its 17 "new" L1 sites are the 1/10 `conn_new`
self-pair burst. AllOpt+peel loses 2 at L2: `conn_new@memcached.c:761` reading `current_time` (10/10 stock, 0/10) and
`lru_pull_tail@items.c:1207` reading `current_time` (2/10 stock, 0/10). Both reads are instrumented in the AllOpt+peel
binary (`objdump -dl`: 761 → 2 calls, 1207 → 1 call, identical in all three builds), so this is not an elision;
the `current_time` granule is the memcached counterpart of the SQLite wal-index granule (one writer every second,
many hot readers) and the second candidate for the per-granule eviction counters. All eight sites that stock
reports in ≥ 9/10 runs are reported by both optimized builds at the same frequency (`stats_state` ×2,
`current_time` readers in `do_item_link`/`lru_maintainer_thread`/`try_read_command_ascii`, `do_item_unlink` vs
`item_remove`/`lru_pull_tail`/`item_crawler_thread`), except `conn_new:761` under AllOpt+peel as stated.
Against the old stock baseline the optimized builds lose nothing except through the same `conn_new:761` site.

## tsan-audit ad0623610ef6 (2026-09-03 04:26–): thirteen shapes closed; per-unit instrumentation = final tree 43111f84d936

Frozen `/extra/alexey/builds/tsan-audit-ad0623610ef6`; stock is code-identical to 297881ddc1c5, so that stock run is the
baseline (linked as `tsan`). Keys now include **L3** (kind + location + writer site; readers collapsed).

**SQLite threadtest3**, N = 10: stock 4.3 ± 1.1 reports/run (union L1/L2/L3 = 5/2/3); tsan-sound 4.7 ± 1.3, AllOpt+peel
4.3 ± 0.8 — both union 5/2/3, **lost 0 / 0 / 0, new 0, relocated 0**. Fifth wal-index site 3/10 stock, 4/10 sound,
5/10 AllOpt+peel.

**memcached**, N = 10 (`results/memcached/2026-09-03-final-ad0623610ef6/`; baseline = the 297881ddc1c5 stock runs, which hit
the `conn_new` burst family in one run):

| config | reports/run | union L1/L2/L3 | lost vs stock L1 / L2 / L3 | new | relocated (L2 / L3) |
|---|---|---|---|---|---|
| stock (297881ddc1c5) | 15.4 ± 7.0 | 35 / 20 / 27 | — | — | — |
| tsan-sound | 10.9 ± 2.2 | 17 / 17 / 11 | 18 / 3 / 16 | 0 | 1 / 2 |
| AllOpt+peel | 13.4 ± 0.8 | 10 / 10 / 4 | 25 / 10 / 23 | 0 | 0 / 1 |

Every L2 and L3 loss is the 1/10 `conn_new` burst family (write/write self-pairs and connection-setup pairs on the
`conn` object; at N = 30 on def2cf34faeb it is present in both builds), plus one `current_time` reader pair each:
`lru_pull_tail:1207` (2/10 → 0/10) for sound and `conn_new:761` (10/10 → 0/10, as on 297881ddc1c5) for AllOpt+peel. The
`current_time` race itself is preserved by both (L3), reported at `do_item_link:495`, `lru_maintainer_thread:1671`,
`try_read_command_ascii:493` 9–10/10; no non-`conn_new` location is lost at L3. All ten sites that stock reports in
≥ 9/10 runs are reported by sound at 9–10/10; AllOpt+peel reports nine of them at 9–10/10 and `conn_new:761` at 0/10.

## Sound whole-program summaries (tsan-audit 43111f84d936), memcached, N = 10

Builds `memcached-{tsan-sound,tsan-all}.wp-43111f84d936` (summaries from `gen_summaries.sh`, id 43111f84d936; static sites
sound 5717, AllOpt+peel 6107 vs 6197 / 6658 per-unit, stock 6748); baseline = the 297881ddc1c5 stock runs
(`results/memcached/2026-09-03-wp-43111f84d936/`):

| config | reports/run | union L1/L2/L3 | lost vs stock L1 / L2 / L3 | new | non-`conn_new` L3 losses |
|---|---|---|---|---|---|
| stock | 15.4 ± 7.0 | 35 / 20 / 27 | — | — | — |
| tsan-sound + summaries | 10.6 ± 0.5 | 10 / 10 / 4 | 25 / 10 / 23 | 0 | none |
| AllOpt+peel + summaries | 13.9 ± 2.6 | 17 / 17 / 11 | 18 (1 reloc.) / 3 / 16 | 0 | none |

Sound + summaries reports the ten frequent stock sites at 10/10 every one (including `conn_new:761`); its L2/L3 losses
are the 1/10 `conn_new` burst family (9 L2 keys) and `lru_pull_tail:1207` (2/10 → 0/10). AllOpt+peel + summaries:
nine of the ten frequent sites at 9–10/10, `conn_new:761` 0/10 (the DE relocation seen on every hash), three burst
L2 keys. No `current_time`/`stats_state`/`do_item_unlink` location is lost at L3 by either. The whole-program mode thus
buys back static reach (sound 6197 → 5717) without changing race-level recall on memcached.

Redis: 0 reports in every build (TSan-clean under `redis-benchmark`), so P2 is trivially preserved
there. Memcached, FFmpeg and MySQL: pending the finished tsan-dev compiler.

_Provenance note (commit ids of the tsan-dev binary: the compiler was built 2026-09-02 07:07 from the tree that then carried 89e5d0078d2f / HEAD 0de7a7350375; tsan-dev rewrote its history on 2026-09-02 18:15, so these ids now resolve only as loose objects; the same content is 775a6d721e02 on the rewritten branch, declared final as e5080b0ab463)._
