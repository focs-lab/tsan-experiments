# Stage B compiler acceptance: tsan-perf-d3bf9f8c39fe vs tsan-dev-729521af8965

Frozen copy `/extra/alexey/builds/tsan-perf-d3bf9f8c39fe/` (perf/stage-b; eviction counters OFF, runtime hot
symbols byte-identical to upstream per tsan-dev's objdump verdict, 67/68 sections; EA fixpoint fix; lost-race
shapes 18-21 fixed). Counters-ON twin `tsan-perf-d3bf9f8c39fe-evictstats/` is for tools/eviction-counters only.

## Static memory-access sites, Stage A configuration set (`tools/perf/static_diff.py`)

| app | config | 729521af8965 | d3bf9f8c39fe | delta |
|---|---|---|---|---|
| memcached | tsan | 6748 | 6748 | 0 |
| memcached | tsan-sound | 6601 | 6643 | +42 |
| memcached | AllOpt-peel / AllOpt+peel / +peel WP | 6367 / 7086 / 6655 | 6408 / 7130 / 6699 | +41 / +44 / +44 |
| redis | tsan | 37941 | 37941 | 0 |
| redis | tsan-sound | 37123 | 37608 | +485 (+1.31 %) |
| redis | AllOpt-peel / AllOpt+peel / +peel WP | 36604 / 42725 / 40525 | 37077 / 43292 / 40692 | +473 / +567 / +167 |
| sqlite | tsan | 57996 | 57996 | 0 |
| sqlite | tsan-sound / AllOpt-peel / AllOpt+peel / +peel WP | 56992 / 56054 / 61895 / 61791 | 57025 / 56087 / 61931 / 61827 | +33 / +33 / +36 / +36 |
| mysql | tsan | 602434 | 602434 | 0 |
| mysql | tsan-sound | 587467 | 597140 | +9673 (+1.65 %) — whole tsan-sound build 1 693 s vs > 3 h on the parent |
| mysql | AllOpt-peel / AllOpt+peel | 565432 / 630723 | 574085 / 640355 | +8653 (+1.53 %) / +9632 (+1.53 %) — builds 1 516 s / 1 812 s |
| ffmpeg | tsan | 514609 | 514609 | 0 |
| ffmpeg | tsan-sound / AllOpt-peel / AllOpt+peel | 496784 / 473938 / 541949 | 497410 / 474557 / 542684 | +626 / +619 / +735 (+0.13 %) |

Stock rows identical everywhere (as required). memcached's +42 equals the announced 6760→6802; SQLite's +33 is
the announced +27 on sqlite3.c plus threadtest3.c.

**Redis +481 (sound), attributed by tsan-dev (per-function list in `/tmp/claude-1005/redis-delta.txt`,
binaries `redis-polygon/redis-sound-h729` (old) and `redis-sound` (new)):** shape 19 (EA-11). A local whose
address is passed to a bodiless pointer-returning callee (`lpGet(p, &v, NULL)`, `zmalloc_usable(n, &usable)`,
`lpGetValue(p, &vlen, &vlong)`) used to be counted non-escaping because the old classifier stopped at "the
result escapes"; now the address escapes at the call, as for any bodiless callee. Per-unit conservative, not a
regression; the whole-program summaries know `lpGet` does not retain its argument, so **the Redis WP row on
d3bf9f8c39fe should recover most of the +481** — **checked when the WP build landed: 40525 → 40692 (+167) against +567 for the same configuration
per-unit — the summaries recover ~400 of the shape-19 sites, the residual +167 being callees outside the linked
IR and the small 18/20/21 share.** Confirmed as predicted.

**All five applications accepted on d3bf9f8c39fe (2026-09-05 13:07): every Stage A configuration built, stock rows identical, every EA-row increase attributed.**

**Chromium is not accepted on this copy:** `vk_safe_struct_utils.cpp` is a second, different cliff (points-to closure copied at every step of a 1 679-call chain, ~n³; extracted copy does not finish in 3 600 s through the stage-b `opt` either, 151 MB). Fixed separately (perf/ea-pointee-views) together with the parser's join sharing; both land in the second stage-b copy. Every EA-containing Chromium row waits for it; no other unit of the five applications showed a cliff.

**Whole-program summary generation time is load-dependent, not compiler-dependent.** The Redis step took
14 min 00 s on d3bf9f8c39fe today against 5 min 52 s on 729521af8965 yesterday, but tsan-dev ran the same
`redis-server.ll` through the whole-program EA print pass with four binaries side by side on four pinned cores
under today's load (Stage B builds plus their replay): parent 737.5 s, fixpoint change alone 736.4 s, the four
shapes alone 724.0 s, stage-b 728.4 s — all within 2 %. Yesterday's number was a quiet machine. (Their run also
gave one more identity proof for the fixpoint change: identical canonical printed states, 256 451 lines, on that
3 264-function module.) A quiet-machine WP generation time, if wanted for a table, must be measured idle.
Shapes 18/20/21 contribute little on Redis.

**MySQL `sql_yacc.cc` under EA on d3bf9f8c39fe: ≈ 20.5 min wall (11:49:30 → 12:10:04), 100 % CPU, 3.4 GB peak,
against 3 h 02 min / 3.5 GB on 729521af8965 — 9x faster, tens of minutes rather than the targeted few.** tsan-dev measured the extracted `MYSQLparse` alone at 1 377 s flow-sensitive / 1 208 s
flow-insensitive under load, 2.8 GB (the parent hits their 1 800 s cap); the fixpoint change removed the
quadratic re-evaluation (17 377 of 47 349 pops skipped) but each evaluation of the 2 261-predecessor join still
merges 2 261 full ~2 000-entry states from scratch and every block keeps its own copy — the state, not the
visits. A second stage-b copy, `tsan-perf-<hash2>` (perf/ea-join-sharing: shared base state + per-block
journal, verdict-identical by construction, proven the same way), will fix that; it differs only in compile
time, so the binaries and static counts built here on d3bf9f8c39fe stay valid and only the MySQL EA rows'
compile time changes.

**MySQL +9 673 (sound, +1.65 %), attributed by tsan-dev:** shape 19 again, with a twist. The added calls are on
locals whose address is passed to a pointer- or reference-returning function that has a body in the unit but
only as a `linkonce_odr` template instantiation (`ut::new_withkey<LatchMeta<…>>` forwarding constructor
arguments in `sync_latch_meta_init`, +226; `std::min/max<T>(const T&, const T&)` in the `rtree_*`
and `decimal_*` families). The escape analysis uses a callee's summary only for an exact definition, and a
`linkonce_odr` body is not exact (the linker may pick another copy), so the call counts as bodiless and, since
shape 19, its address arguments escape. Conservative, not a regression; the whole-program summaries do not
obviously take it back because the instantiations stay `linkonce_odr` in the linked module. **Candidate yield
item for Alexey:** trust a `linkonce_odr` body's summary under the one-definition rule ("does not retain its
argument" is a semantic property shared by every copy). Per-function list: `/tmp/claude-1005/mysql-delta.txt`;
binaries `installs/mysql-tsan-sound` (parent) and `installs/mysql/mysql-tsan-sound` (stage-b).

## Two more facts from the tsan-dev lane (2026-09-05, while deriving the thread-free lists)

- **glibc 2.38+ renames the C23-affected conversions:** on this machine the IR calls `__isoc23_strtol`,
  `__isoc23_strtoul`, `__isoc23_strtoll`, `__isoc23_strtoull`, `__isoc23_sscanf`, names neither
  TargetLibraryInfo nor the built-in thread-free list knows (also uncovered: `getsubopt`, `__getdelim`,
  `preadv`). Each is a bodiless callee: it ends the single-threaded prefix (memcached: 22 call sites, the first
  early in option parsing, so STC's prefix ends before libevent) and, for the escape analysis, its arguments
  escape. The `tsan-sound-tfn` rows vouch them explicitly (sound); the proper fix (aliases on the built-in list,
  EA treating them as their base functions) lands in the second stage-b copy.
- **Lost-race shape 22** (a pointer to a local stored through a library call's out-parameter — `strtol`'s end
  pointer — and then published) reproduces on 729521af8965 and d3bf9f8c39fe; fixed in the second copy. It can
  only add instrumentation, so **every sound row on d3bf9f8c39fe is a lower bound of the sound count by a small
  amount.**

## `-tsan-thread-free-names` rows (Stage B lever, from tsan-dev's lists)

Syntax `-mllvm -tsan-thread-free-names=a,b,c` (exact symbol names; built-in creators cannot be overridden;
feeds STC's `isKnownThreadFree` for bodiless callees, per unit and whole-program; LO/SWMR inherit STC's
verdicts; on the yield copy DynSTC's run-ending rule uses the same predicate). Sound rule: vouch only
functions outside the linked IR that neither start a thread nor take a callback. Rows: memcached
`tsan-sound-tfn` (libevent's `event_get_version, event_config_new, event_config_set_flag,
event_base_new_with_config, event_config_free` + the glibc aliases) and `tsan-sound-tfn-wp`; Redis `sound-tfn`
(`sd_notify` + the aliases). None for SQLite, FFmpeg, MySQL (x264/x265/OpenSSL init are exactly what must not
be vouched unread). Correction from tsan-dev the same hour: the `__isoc23_*`/`__isoc99_*` families are already
thread-free for STC through a built-in prefix rule, so only `getsubopt`, `__getdelim`, `preadv` genuinely cut a
prefix (`getsubopt` is in memcached's option parsing); the aliases stay in the list as harmless redundancy and
still cost escape-analysis precision (unknown to the retention table) — a yield item for the next copies.

Static counts on d3bf9f8c39fe (memory-access sites): memcached sound 6 643 → sound-tfn **6 590** (−53) →
sound-tfn-wp **6 227** (−416 vs sound; the lowest memcached count of any sound row, below Stage A's AllOpt-peel
6 367). Redis sound 37 608 → sound-tfn 37 608 (0: nothing per unit) → sound-tfn-wp 35 372 (−2 236 vs sound;
plain sound-wp is **35 372 as well**, so on Redis the list adds exactly nothing beyond the summaries —
its runtime rows are dropped from the sweep as duplicates of sound / sound-wp). memcached plain sound-wp is
6 280, so there the list adds −53 on top of the summaries (6 227): both memcached lever rows stay.

## Yield copy tsan-yield-fdf7a4dd41e9 vs stage-b d3bf9f8c39fe (static, main rows; builds in progress)

memcached: tsan 6748 = 6748; sound 6643 → 6640 (−3), AllOpt-peel 6408 → 6405 (−3), AllOpt+peel 7130 → 7127 (−3),
sound-wp 6280 → 6269 (−11), DynSTC (tsan-stmt) 6810 = 6810 — exactly the announced C5 effect (memcached −3 under
EA/sound; C1 shows only in NumThreadCountLoads). Other applications follow as their builds land.
redis: tsan 37941 → 37941 (+0); sound 37608 → 37605 (-3); AllOpt-peel 37077 → 37042 (-35); AllOpt+peel 43292 → 43243 (-49); sound-wp 35372 → 35328 (-44); DynSTC 37882 → 37878 (-4)
sqlite: tsan 57996 → 57996 (+0); sound 57025 → 57006 (-19); AllOpt-peel 56087 → 56064 (-23); AllOpt+peel 61931 → 61872 (-59); sound-wp 56890 → 56698 (-192); DynSTC 57957 → 57961 (+4)
ffmpeg: tsan 514609 → 514609 (+0); sound 497410 → 497310 (-100); AllOpt-peel 474557 → 473446 (-1111); AllOpt+peel 542684 → 541450 (-1234); DynSTC 514493 → 514540 (+47)
The DynSTC (`tsan-stmt`) rows moved by +47 (FFmpeg) and +4 (SQLite) in the binary count; attributed by
tsan-dev to **back-end code duplication, not instrumentation**: the IR after the pass has identical
`__tsan_read/write` calls with both copies (sqlite3.c: 56 196, identical per function over 1 431 functions),
while the object count moves both ways per function (tail duplication / branch folding around C1's relocated
guard; the guard's thread-count load is a plain load, never a `__tsan_` call). So the objdump count carries
±0.01 % codegen noise on DynSTC rows; a duplication-free static count must be taken on the IR. DynSTC rows are
recorded as "unchanged instrumentation, ±codegen". MySQL's yield rows pending.

## Parser compile-time fix landed on the stage-b line (tsan-dev, 2026-09-05 evening)

perf/ea-join-sharing 35e03631a20a, cherry-picked onto stage-b as 2dcc82078a60: the `MYSQLparse` extract through
`opt` goes 1 379 s → **12.7 s** (flow-sensitive), 1 176 s → 13.4 s (flow-insensitive), 2.8 → 1.8 GB;
sqlite3.c 7.9 → 5.1 s. Identity: a verify mode recomputing every join and transfer from scratch found no
difference over the suites, the 28-module corpus and all 47 349 pops of the extract; static counts identical on
all 112 corpus rows; the whole-program print of `redis-server.ll` identical. Expect `sql_yacc.cc` at roughly the
no-EA time plus seconds on the second copy (hash2 = stage-b with shape 22 + this + the Chromium pointee-views
fix, built in the first announced gap). Methodological note from the same message: the printed-state *digests*
are stable only when both binaries run at the same time (the printer's block order varies between runs), so the
identity proofs that count are the assertion verifiers and the static counts.
The Chromium fix followed the same evening (perf/ea-pointee-views 9e678cc6ae3e): the `vk_safe_struct_utils`
extract goes from "not finished in 3 600 s" to 50 s in both EA modes, verdict-identical on every gate; memory
on that unit is still high (18 GB, every block holding the full points-to clique), which the parser fix's
shared-base states should shrink — the two are being merged as perf/stage-b2 with the full gate set, and
hash2 is that merge. Expected on hash2: `sql_yacc.cc` ≈ no-EA time + ~15 s; Chromium EA rows compile normally.
mysql: tsan 602434 = 602434; sound 597140 → 596943 (−197); AllOpt-peel 574085 → 573765 (−320); AllOpt+peel 640355 → 639937 (−418); DynSTC 602809 → 602814 (+5, codegen). **Yield copy accepted on all five applications: stock identical, every EA/DE row non-positive, DynSTC ±codegen.** (Builds finished 2026-09-05 17:56; recorded 2026-09-07 after a session loss.)

## Two compilers' builds coexist: resolution by hash (2026-09-07)

Building the yield copy's rows put fdf7a4dd41e9 binaries into every canonical build directory and archived the
d3bf9f8c39fe ones as `old-builds/<dir>.d3bf9f8c39fe` (the archive rule added on 09-05). The runner's
provenance gate refused the first Stage B pilot for exactly that reason ("STALE BINARY … compiler_head
fdf7a4dd41e9, sweep hash d3bf9f8c39fe"), which is the gate working. `p5_binary` now resolves by the sweep's
hash: the canonical directory when its stamp matches, else `old-builds/<dir>.<hash>`; verified for all five
applications on both hashes. Nothing was moved.

