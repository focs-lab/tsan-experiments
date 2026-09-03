# EA flow-sensitive vs flow-insensitive: static instrumentation counts (2026-09-02, tsan-dev fbd24d688c92)

Input for Alexey's ruling on the escape-analysis notion (current flow-sensitive cross-block elision vs
per-object flow-insensitive escape, hidden flag `-mllvm -tsan-ea-flow-insensitive`). Diagnostic builds in
tagged directories (`*.fi-probe-fs` = default, `*.fi-probe-fi` = flag on), canonical build dirs untouched;
`tools/static_count_tsan_instrumentation.py`, memory-access instrumentation sites (`__tsan_read*/write*`
call sites in the binary). Whole-program summaries not used (per-TU analyses, same on both sides).

| binary | stock | EA-only, flow-sens. | EA-only, flow-insens. | AllOpt, flow-sens. | AllOpt, flow-insens. |
|---|---|---|---|---|---|
| redis-server 7.0.15 | 36881 | 34916 (−5.3 %) | 35370 (−4.1 %) | 37365 (+1.3 %) | 37840 (+2.6 %) |
| memcached 1.6.29 | 6526 | 5933 (−9.1 %) | 6102 (−6.5 %) | 5022 (−23.0 %) | 5201 (−20.3 %) |

AllOpt = `dom_peeling-ea-lo-st-swmr` (Redis) / `tsan-all` (memcached; includes peeling). Redis AllOpt exceeds
stock because loop peeling adds sites that DE no longer removes; memcached AllOpt profits from STC (memcached
has a `main`, Redis's instrumented code is mostly reached after thread creation). tsan-dev-f's sqlite3.c rows
for comparison: stock 54657, EA-only 44248 → 46929, AllOpt 43569 → 46199.

Lock ownership on memcached (LO-only, `-mllvm -tsan-use-lock-ownership`): March paper build 6500 (−0.4 %,
LO was effectively a no-op in the paper's builds); final tsan-dev 6480 (−0.7 %). Striped `item_locks` /
`lru_locks` are variable-index and therefore unknown to the sound LO; the reach was never large here.

Build dirs: `nosql/redis/redis-polygon/redis-{ea,dom_peeling-ea-lo-st-swmr}.fi-probe-{fs,fi}`,
`nosql/memcached/memcached-{tsan-ea,tsan-all}.fi-probe-{fs,fi}`, `nosql/memcached/memcached-tsan-lo.final-fbd24d68`
(each with `build_info.txt`). Hooks used: `EXTRA_TSAN_FLAGS=... BUILD_TAG=... ./redis.sh --compile-only`,
`EXTRA_TSAN_FLAGS=... BUILD_TAG=... ./build_memcached.sh <cfg>`.

## Final hash b4bf8b8f4613: bare per-point / sound flow-sensitive (default) / per-object

Alexey chose the sound flow-sensitive rule (`-tsan-ea-sound-flow-sensitive`, default on): an access to a
not-yet-escaped object is elided only if every escape site reachable after it is release-like or none is
reachable. Redis rows (memory-access sites; per-object column from fbd24d688c92, a lower bound until the
cached-union bug in `-tsan-ea-flow-insensitive` is fixed):

| redis-server 7.0.15 | stock | bare per-point (`-tsan-ea-sound-flow-sensitive=false`) | sound per-point (default) | per-object (`-tsan-ea-flow-insensitive`) |
|---|---|---|---|---|
| EA-only | 36881 | 34916 (−5.3 %) | 35284 (−4.3 %) | 35370 (−4.1 %) |
| AllOpt | 36881 | 37365 (+1.3 %) | 37767 (+2.4 %) | 37840 (+2.6 %) |

Build dirs `redis-polygon/redis-{ea,dom_peeling-ea-lo-st-swmr}.ea-{bare,sound}-b4bf8b8f`. tsan-dev-f's rows on the
same hash: sqlite3.c EA-only 44251 / 45960 / 46933 [54657], AllOpt 43572 / 45237 / 46200; memcached EA-only
6088 / 6241 / 6256 [6687], AllOpt 4582 / 4728 / 4740 (their memcached count is a different measure from mine).

Label convention agreed with tsan-dev-f for the response tables: **AllOpt+peel** = the paper's AllOpt
(`dom_peeling-ea-lo-st-swmr`: DE + peeling + EA + LO + STC + SWMR, the rows above); **AllOpt−peel** =
`dom-ea-lo-st-swmr`. Counter convention in all my tables: `__tsan_read*/write*` incl. unaligned only.
