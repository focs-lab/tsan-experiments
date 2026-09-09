# The paper's SQLite 2.77x: where it went

Stage A measured SQLite AllOpt-peel at 1.051 against the paper's 2.773. Three candidate explanations were
tested and the answer is a mixture of two of them, plus one that is not the compiler at all.

## 1. The analyses' reach collapsed when they were made sound (the main effect)

Instrumentation actually emitted into `threadtest3` (objdump, `call __tsan_read/write/func`):

| build | stock TSan | AllOpt-peel | removed |
|---|---|---|---|
| paper compiler e90a3fc41004 | 58 324 | 32 635 | **44 %** |
| final compiler 729521af8965 | 60 789 | 58 857 | **3.2 %** |

The soundness fixes (STC's bodiless-callee rule, LO's thread-start exemption, DE's `isSyncFree` allowlist)
took the reach from 44 % of accesses to 3 %. Everything else follows from that: a 3 % reduction cannot buy a
2.77x speedup, and the measured 1.059 is what 3 % is worth.

## 2. Even at 44 % reach, this machine gives 1.27, not 2.77

Both configurations built with both compilers and measured in one window, N = 2, 48 pinned CPUs
(`tools/perf/sqlite_baseline_probe.sh`, `results/2026-09-04-729521af8965-baseline/baseline.md`):

| subtest | SU final | SU paper compiler | SU March |
|---|---|---|---|
| walthread1 | 0.90 | 1.12 | 1.60 |
| walthread2 | 0.90 | 1.18 | 1.63 |
| dynamic_triggers | 1.73 | 1.33 | 1.92 |
| checkpoint_starvation_1 | 0.80 | 1.41 | 2.71 |
| checkpoint_starvation_2 | 1.00 | 1.00 | 1.02 |
| stress1 | 1.33 | 1.46 | **21.91** |
| stress2 | 0.99 | 1.48 | 4.15 |
| **geomean** | **1.059** | **1.271** | **2.773** |

So the paper's own compiler, on this machine today, reproduces 1.271 — not 2.773.

## 3. The March *baseline* run was anomalously slow, and that is what the 2.77x rests on

On `stress1` the March stock-TSan run did 6 417 iterations in 10 s. The **same compiler**, same source, same
flags, on this machine today does 106 704 — 16.6x more. Native differs by only 1.2-1.3x between the two, so
this is specific to the instrumented run, not to the machine being generally faster. Ruled out: subtest
durations (identical), build flags (the March-era script at git 0632e34 is byte-identical in the relevant
lines), race reports (none, `report_bugs=0` in both), machine width (48 vs 96 CPUs changes the geomean from
1.038 to 0.991, `sqlite_cpuscale_probe.sh`).

`stress1` alone carries the paper's SQLite geomean: dropping it takes the March figure from 2.773 to 1.965.
So the headline number depends on one subtest of one unrepeated run whose baseline cannot be reproduced.

## Secondary: the final compiler's *stock* TSan is slower than the paper compiler's

Same `-fsanitize=thread`, 4 % apart in emitted instrumentation, but the paper compiler's stock build is ~1.4x
faster on this workload (e.g. `checkpoint_starvation_1` 140 444 vs 52 576, `stress1` 106 704 vs 80 244). Explained
by tsan-dev-f the same morning: the eviction counters added for P3 (`NoteEviction`, fe1e4f609675) do a locked
increment on a global cache line per shadow eviction, and the out-of-line helper inside the inlined access check
costs three register saves on every `__tsan_read/write`. Confirmed here: `TSAN_OPTIONS=print_evictions=1` on
`checkpoint_starvation_1` reports 3.0e8 evictions in 10 s on the 729521af8965 binary. Consequence: SU rows on
729521af8965 stand (both sides share the runtime); SD rows are inflated and are not to be quoted as absolutes.
The fix (counters behind a build option, off by default) lands on the performance branch Stage B will use.

## Addendum 2026-09-08: how far outside `stress1`'s natural spread the March baseline sits

Stage B on `tsan-perf-d3bf9f8c39fe` (counters OFF) gives 65 instrumented `stress1` runs, five each across
thirteen configurations, all on the pinned set. The subtest's own run-to-run envelope:

| | iterations |
|---|---|
| min | 81 553 |
| p25 | 100 197 |
| median | 107 239 |
| p75 | 123 602 |
| max | 187 109 |

So `stress1` spans **2.29x from min to max** with a CV of about 16 % inside the bulk, and it is not bimodal:
the largest gap in the sorted values separates only three points at the top, and the rest is a continuum. The
same shape holds for `dynamic_triggers` (2.05x, CV 16 %); every other subtest sits at 0-4 %.

That sets a scale for section 3. The March stock-TSan `stress1` run did 6 417 iterations where the same
compiler does 106 704 today, a factor of 16.6. The natural envelope of this subtest, measured over 65 runs, is
2.29x end to end. **The March baseline is therefore about seven times further from today's median than the
subtest's entire observed range**, so run-to-run variance does not explain it and no number of repetitions
would have produced it. Whatever happened to that run was not sampling noise.

This is also why the Stage B tables report a second geometric mean over the subtests whose **pooled** CV, taken
across every configuration rather than off the baseline's five runs, is at most 5 %. For SQLite that excludes
`stress1` (19.9 %), `dynamic_triggers` (16.1 %) and `stress2` (5.5 %), leaving four of seven. Pooling matters
here: read off the baseline alone, `stress1` measures 6.4 % and its exclusion turns on where a threshold
happens to fall; pooled over 65 runs it measures 19.9 % and the separation is unambiguous. The all-subtest column stays the headline
because it is the only one comparable with the paper's definition; the restricted column is what the data can
actually resolve, and it is the one that made SQLite's DynSTC row conclusive
(`tools/notes/dynstc-sign-flip-2026-09-08.md`).
