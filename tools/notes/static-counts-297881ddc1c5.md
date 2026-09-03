# Static instrumented-access counts: tsan-dev b4bf8b8f4613 (old) vs tsan-audit 297881ddc1c5 (new)

Reported by tsan-dev-f on 2026-09-03 03:05 (memcached 26 modules -O2; sqlite3.c; shell.c; per-TU sound default).
"new" includes the upstream capture-tracking fix, which raises the *stock* baseline (stock had a false negative
on field/element writes to captured local aggregates). The two stock columns are separate baselines.

| config | mc-old | mc-new | sql-old | sql-new | sh-old | sh-new |
|---|---|---|---|---|---|---|
| stock | 6687 | 6911 | 54657 | 56636 | 6096 | 6452 |
| EA | 6241 | 6554 | 45960 | 55167 | 5486 | 6156 |
| LO | 6641 | 6902 | 54657 | 56636 | 6096 | 6452 |
| STC | 5794 | 6515 | 54657 | 56636 | 3929 | 4336 |
| SWMR | 6107 | 6893 | 54657 | 56636 | 5955 | 6380 |
| DE+peel | 7238 | 7508 | 59187 | 61323 | 6973 | 7408 |
| sound-only | 4883 | 6140 | 45960 | 55167 | 3368 | 4083 |
| AllOpt+peel | 5375 | 6696 | 49750 | 59824 | 3790 | 4610 |
| AllOpt+peel + `-tsan-stc-assume-whole-program` (unsound repro switch) | n/a | 6157 | n/a | 59824 | n/a | 4203 |

Reading (tsan-dev-f): the per-TU sound default means STC and LO no longer assume an externally visible function
is single-threaded or that an opaque call keeps a lock held, and SWMR/LO no longer judge external globals; that
is most of the memcached and shell.c change (LO 46 → 9 elisions on memcached). The EA drop on sqlite3.c under EA
alone (45960 → 55167) is the EA soundness chain (unknown-operand rule ~4.6k, unseen-pointee ~1.3k, whole-object/
field lattice, transitive stores). The sound recovery of whole-program reach is the summaries mode (audit item S,
own hash and row to come). Twelve confirmed lost-race shapes closed on this hash; 12-config lit matrix 289/0.

Whole-application counts on this hash (my measure, `static_count_tsan_instrumentation.py`) are recorded with the
preservation runs in `tools/preservation/README.md`.

## tsan-audit ad0623610ef6 (2026-09-03 04:20, from tsan-dev-f): thirteen shapes closed; stock unchanged

| config | mc-297881 | mc-ad0623 | sql-297881 | sql-ad0623 | sh-297881 | sh-ad0623 |
|---|---|---|---|---|---|---|
| stock | 6911 | 6911 | 56636 | 56636 | 6452 | 6452 |
| EA | 6554 | 6770 | 55167 | 55725 | 6156 | 6309 |
| LO | 6902 | 6902 | 56636 | 56636 | 6452 | 6452 |
| STC | 6515 | 6515 | 56636 | 56636 | 4336 | 4336 |
| SWMR | 6893 | 6893 | 56636 | 56636 | 6380 | 6380 |
| DE+peel | 7508 | 7510 | 61323 | 61323 | 7408 | 7409 |
| sound-only | 6140 | 6356 | 55167 | 55725 | 4083 | 4235 |
| AllOpt+peel | 6696 | 6865 | 59824 | 60380 | 4610 | 4757 |

Movement = EA-7 (arguments of address-taken / externally visible functions escape) and EA-8 (setbuf/setvbuf retain,
realloc aliases its argument, name-only allocator list removed); LO-3/5 (stale held-lock record), DE-1..4, PASS-3,
RT-1/2 do not change these counts. Gate 12×290/0, check-tsan 369/0. Whole-program summaries mode (sound, keyed on
external-linkage entities; `-tsan-whole-program`, `-tsan-summary-dir`, `-tsan-summary-id`) is the next hash.

## tsan-audit 43111f84d936 (final audit tree, 2026-09-03 04:45): whole-program summaries (sound) — my whole-binary counts

memcached 1.6.29, `static_count_tsan_instrumentation.py` on the linked binary (stock 6748 on this compiler front):

| config | per-TU (ad0623610ef6 = 43111f84d936 per-unit) | + sound whole-program summaries (`gen_summaries.sh`, `-tsan-whole-program`, id 43111f84d936) |
|---|---|---|
| tsan-sound | 6197 (−8.2 %) | 5717 (−15.3 %) |
| AllOpt+peel | 6658 (−1.3 %) | 6107 (−9.5 %) |

tsan-dev-f's module-level measure on the same hash: sound 6356 → 5852, AllOpt+peel 6865 → 6262 (unsound per-unit
`-tsan-whole-program` switch: 5975). Build dirs `memcached-{tsan-sound,tsan-all}.wp-43111f84d936`, summaries in
`nosql/memcached/summaries-43111f84d936/` (PROVENANCE.txt). The only summary-related build warnings are
`-Wunused-command-line-argument` on the five link steps (no compilation there).
