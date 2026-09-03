# Dominance Elimination yield: paper compiler vs tsan-dev

Why the hardened compiler's DE (`-tsan-use-dominance-analysis`) removes ~1.5 % of the memory-access
instrumentation where the paper reported ~30 %, and which of the paper's two soundness defects the
yield came from. All numbers 2026-09-02, same machine, same scripts and flags; only the compiler
differs.

Compilers

| name | path | commit | what it is |
|---|---|---|---|
| paper | `/extra/alexey/llvm-project-paper/llvm/build/bin/clang` | e90a3fc41004 | the paper's state of focs-lab `ThreadSanitizer.cpp`; reproduces the March 2026 static counts exactly |
| paper+must-alias | `/extra/alexey/llvm-project-paper-mustalias/llvm/build/bin/clang` | 6ac95657262d | paper + one change: DE's same-location test restricted to `AA->isMustAlias` (diagnostic build, git worktree on branch `paper-mustalias`) |
| tsan-dev | `~/dev/llvm-project-focs-lab/llvm/build/bin/clang` | 89e5d0078d2f (HEAD 0de7a7350375 adds only tests) | hardened compiler |

## 1. Static instrumentation of SQLite `threadtest3` (`tools/static_count_tsan_instrumentation.py`, memory-access call sites)

| build | paper | paper+must-alias | tsan-dev |
|---|---|---|---|
| `tsan` | 55531 | 55531 | 55531 |
| `tsan-dom` | 38140 (−31.3 %) | 54580 (−1.7 %) | 54672 (−1.5 %) |
| `tsan-dom_peeling` | 44200 (−20.4 %) | 63420 (+14.2 %) | 60384 (+8.7 %) |
| AllOpt (`dom_peeling-ea-lo-st-swmr`) | 34111 (−38.6 %) | — | 48907 (−11.9 %) |

Redis `redis-server` (paper / tsan-dev): `tsan` 36881 / 36881; `dom` 22436 (−39.2 %) / 36310 (−1.5 %);
`dom_peeling` 27407 (−25.7 %) / 42242 (+14.5 %); `ea` 34388 / 34916.

## 2. Pass statistics on `sqlite3.c` alone (`-mllvm -stats`, `stats/sqlite3c.<tag>.txt`, `./stats.sh`)

Baseline (`tsan`): 36746 instrumented reads + 17911 writes in all three compilers.

| flags | counter | paper | paper+must-alias | tsan-dev |
|---|---|---|---|---|
| `-tsan-use-dominance-analysis` | ignored due to dominance | 16662 | 678 | 639 |
|  | ignored due to post-dominance | 683 | 192 | 236 |
|  | total omitted (of 54657) | 17345 (31.7 %) | 870 (1.6 %) | 875 (1.6 %) |
| `-dom` only | dominance | 16662 | 678 | 639 |
| `-postdom` only | post-dominance | 8382 | 312 | 438 |
| `-postdom` + `-tsan-postdom-aggressive` | dominance / post-dominance | — | — | 639 / 279 |
| `-tsan-use-dominance-analysis -tsan-use-loop-peeling=true` | reads / writes instrumented | — | — | 39707 / 19480 (+8 % / +9 %); dominance 789, post-dominance 252 |

(`-postdom` only in the paper compiler is 8382 vs 683 in the combined mode because the combined
mode runs the dominance step first and the post-dominance step then sees fewer candidates.)

## 3. Why: two defects of the paper's DE (`de_probe.c`, `./probe.sh`)

Each function stores twice; a sound DE may elide the second store only in `f_same` (same location,
nothing in between) and `f_lock` (acquiring a lock cannot make the first store visible). Remaining
`__tsan_write4` calls at `-O1 -tsan-use-dominance-analysis-dom`:

| function | between the two stores | paper | paper+must-alias | tsan-dev |
|---|---|---|---|---|
| `f_same` | nothing (`x=1; x=2`) | 1 | 1 | 1 |
| `f_lock` | `pthread_mutex_lock` | 1 | 1 | 1 |
| `f_unlock` | `pthread_mutex_unlock` | 2 | 2 | 2 |
| `f_field` | different fields `st.a=1; st.b=2` | **1** | 2 | 2 |
| `f_index` | `arr[i]=1; arr[j]=2` | **1** | 2 | 2 |
| `f_cond` | `pthread_cond_wait` | **1** | **1** | 2 |
| `f_join` | `pthread_join` | **1** | **1** | 2 |
| `f_sem` | `sem_wait` | **1** | **1** | 2 |
| `f_ext` | unknown external function | **1** | **1** | 2 |

Defect 1 — *location test*: the paper's `eliminateInstrByPrePostDominance` accepted the candidate when
`getUnderlyingObject(Curr) == getUnderlyingObject(Dom) || AA->isMustAlias(Curr, Dom)`, i.e. any two
accesses to the same struct/array/alloca counted as the same location. `st.b = 2` after `st.a = 1`
and `arr[j]` after `arr[i]` lost their instrumentation; a race on `st.b` or on `arr[j]` alone becomes
invisible. tsan-dev's `locationCovers` requires must-alias or the same SSA base with the same constant
offset.

Defect 2 — *sync-free externals*: `SyncFreeInfo` initialised `IsFuncDangerousGlobal[&F] = false` for
every function including declarations; only names in `LockNames`/`UnlockNames`, TLI libfuncs and
intrinsics were classified, so `pthread_cond_wait`, `pthread_join`, `sem_wait` and any unknown
external were treated as sync-free and the DE elided across them (`x=1; pthread_cond_wait(); x=2` →
the second store, which may now race with a thread woken by the wait, is not instrumented).
tsan-dev's `classifySyncEffect` returns `SYNC_UNKNOWN` for anything without a body.

Attribution: fixing defect 1 alone (paper+must-alias) brings the SQLite yield from 17345 to 870 omitted
accesses — the same 1.6 % that tsan-dev reaches with both fixes. Essentially all of the paper's DE
reduction on SQLite (and, by the Redis numbers, on Redis) came from eliding accesses to *other
offsets of the same object*; the sync-free-externals defect changes which accesses are elided but
adds almost no volume on top of it (678 → 639 dominance eliminations).

Consequences for the rebuttal / revision: the paper's DE static-reduction figures (and the share of the
speedup attributable to DE) are not reproducible with a sound location test; the honest DE yield on
these applications is ~1.5 %, and loop peeling is a net loss (+9–15 % static instrumentation) once DE
cannot pay for the duplicated loop bodies. The sound passes (EA, STC, SWMR, LO) are unaffected:
`tsan-ea` is 34388 (paper) vs 34916 (tsan-dev) on Redis and 43462 vs 45037 on SQLite; the tsan-dev sound bundle (EA+LO+ST+SWMR) gives 44988 on SQLite.

_Provenance note (commit ids of the tsan-dev binary: the compiler was built 2026-09-02 07:07 from the tree that then carried 89e5d0078d2f / HEAD 0de7a7350375; tsan-dev rewrote its history on 2026-09-02 18:15, so these ids now resolve only as loose objects; the same content is 775a6d721e02 on the rewritten branch, declared final as e5080b0ab463)._
