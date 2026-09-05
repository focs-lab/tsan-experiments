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

