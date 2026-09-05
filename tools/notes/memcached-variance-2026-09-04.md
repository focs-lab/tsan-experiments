# memcached: how much of the memcached column is noise

## The March (paper) artefacts carry ~10 % of spread inside a single run

The paper's memcached numbers are one memtier invocation per configuration; memtier's own `-x 5` prints the
best, the worst and the average of its five iterations. From
`archive-2026-09/nosql_memcached_results.good.March6.tar.zst`:

| config | average ops/s | best-vs-worst spread |
|---|---|---|
| orig | 914538 | 1.0 % |
| tsan | 410546 | 9.5 % |
| tsan-all (AllOpt) | 441436 | 8.0 % |
| tsan-all_stmt (DynSTC) | 435740 | 0.5 % |
| tsan-dom_peeling | 432936 | 2.7 % |
| tsan-stmt | 402879 | 12.0 % |

Ratio to `tsan`, with the envelope obtained by taking each side at its own best and worst iteration:

| config | ratio (as reported) | envelope |
|---|---|---|
| tsan-all | 1.075 | [1.010, 1.203] |
| tsan-all_stmt | 1.061 | [1.018, 1.125] |
| tsan-dom_peeling | 1.055 | [0.999, 1.130] |
| tsan-dom | 1.039 | [0.993, 1.102] |
| tsan-lo | 1.012 | [0.922, 1.095] |

The paper states "a modest speedup of 1.07x with our full optimization suite" and "1.03x" for DE and
DE+Peeling (`4-experiments.tex:91`). The 1.07 sits just above the envelope's lower edge and the 1.03-1.05
rows overlap 1.0. Reviewer C's request for run counts and variance is well aimed at this column.

## On 729521af8965 no configuration is faster than stock TSan on memcached

Stage A, N = 3, 48 pinned CPUs, run-major (`tools/perf/results/2026-09-04-729521af8965/perf_memcached.md`):

| config | median ops/s | CV | SU vs tsan | static sites |
|---|---|---|---|---|
| orig | 5.079e6 | 8.1 % | 14.06 | 0 |
| tsan | 3.613e5 | 9.0 % | — | 6748 |
| AllOpt-peel | 3.525e5 | 9.3 % | 0.976 | 6367 |
| tsan-sound | 2.993e5 | 11.1 % | 0.828 | 6601 |
| AllOpt+peel | 2.961e5 | 11.9 % | 0.820 | 7086 |
| AllOpt+peel (WP summaries) | 2.903e5 | 13.7 % | 0.803 | 6655 |

Two reasons this is not a surprise: the hardened analyses remove only 2-6 % of the sites on memcached (the
STC/SWMR fail-closed rules), and loop peeling *adds* 5 % (7086 > 6748). What is not explained by
instrumentation is the size of the gap: `tsan-sound` carries strictly less instrumentation than `tsan` (no
function has more `__tsan_read/write` calls; per-function objdump comparison) and is still 17 % slower, in the
slow wall-time mode on every run while AllOpt-peel is in the fast mode on every run.

## Correction: the sound build is not systematically slower — the modes are not sticky per binary

The layout probe (`tools/perf/layout_probe.sh`, `results/2026-09-04-729521af8965-layout/layout.md`) rebuilt
`tsan-sound` at `-falign-functions=16/32/64` — same source, same flags, 6500 `__tsan_read/write` calls in every
binary, only the code layout differs:

| -falign-functions | N | median ops/s | CV | wall s |
|---|---|---|---|---|
| 16 | 3 | 359320 | 12.2 % | 84-102 |
| 32 | 3 | 358439 | 12.2 % | 81-99 |
| 64 | 3 | 357471 | 10.8 % | 81-99 |

0.5 % across alignments: **layout does not explain the gap**. And the same configuration that measured
2.99e5 in the sweep measures ~3.58e5 here, i.e. stock TSan's level, with every alignment spanning the whole
bimodal range rather than sitting in the slow mode. So the sweep's three `tsan-sound` runs landing together at
103 s was a coincidence of that window, not a property of the binary, and the "tsan-sound is 17 % slower"
reading above (and in the first message sent to tsan-paper on 2026-09-04) is withdrawn.

The probe was also under-designed: it measured only one configuration, with no stock baseline in the same time
window, so it cannot separate "layout matters" from "the machine is faster now". The placement probe runs both
configurations together and is the one to trust.

## Open: the two wall-time modes

Every memcached run lands near 85-88 s (345-372 k ops/s) or near 103-107 s (283-307 k ops/s), and the mode is
sticky per binary rather than random. Not foreign load (the slowest-throughput pilot run had the lowest
outside-CPU busy share), not NUMA (one node), not the run order (configurations are interleaved run-major).
Two probes are queued to settle it: `tools/perf/memcached_placement_probe.sh` (client and server sharing the 48
pinned CPUs vs. disjoint sets vs. 24 server threads, both configurations, N = 5) and
`tools/perf/layout_probe.sh` (the same configuration rebuilt at `-falign-functions=16/32/64`, which changes
code layout and nothing else).

Note also that this driver runs the server with one thread per *pinned* CPU (48) while the paper's
`run-memcached.sh` uses `nproc` (112) unpinned; native throughput differs by 5.5x between the two setups
(914 k vs 5.08 M ops/s), so the Stage A memcached column is not comparable to the March one.
