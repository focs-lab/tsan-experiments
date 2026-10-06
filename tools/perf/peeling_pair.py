#!/usr/bin/env python3
"""peeling_pair.py <results-root> — the pre-registered AllOpt+peel vs AllOpt-peel comparison.

Registered 2026-09-15 19:02, before any leg finished (data/notes/preregistration-2026-09-13.md in the artifact): per
application, the ratio of the two configurations' per-test medians, geomean over the resolvable subtests,
95 % bootstrap interval, B = 2000, seed = 1. Ratio > 1 means peeling is FASTER. No Bonferroni: the branch
rule counts applications rather than testing them jointly.

EVERY ROW ALSO PRINTS WHAT A NULL WOULD LOOK LIKE. "The interval includes 1.0" is not a finding on its own
-- it is the same output whether peeling has no effect or the workload cannot resolve the effect it has.
So each row carries the half-width of its own interval as a resolution floor: an effect smaller than that
is indistinguishable from no effect *in this data*, and a crossing interval on a row with a wide floor says
nothing at all. memcached is the case in point: one metric, ops_sec, and a floor near 5 %.

The rule of 2026-09-16 -- every result line should have to say what it would look like if
the thing it measures were absent -- applied to the one comparison this campaign registered in advance.
"""
import importlib.util, os, statistics, sys

A = "tsan-dom-ea-lo-st-swmr"           # AllOpt-peel
B = "tsan-dom_peeling-ea-lo-st-swmr"   # AllOpt+peel

def load(path):
    spec = importlib.util.spec_from_file_location("agg", path)
    m = importlib.util.module_from_spec(spec); sys.modules["agg"] = m; spec.loader.exec_module(m)
    return m

def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "results/campaign-f3deebfbab60/primary"
    agg = load(os.path.join(os.path.dirname(os.path.abspath(__file__)), "aggregate.py"))
    print(f"pre-registered peeling pair — AllOpt+peel vs AllOpt-peel  (>1 = peeling faster)\n{root}\n")
    done = []
    for app in ("redis", "memcached", "sqlite", "ffmpeg", "mysql"):
        adir = os.path.join(root, app)
        if not os.path.isdir(adir): continue
        per_cfg, hib = agg.collect(root, app)
        if A not in per_cfg or B not in per_cfg:
            missing = [c for c in (A, B) if c not in per_cfg]
            print(f"  {app:10s} not comparable: {', '.join(missing)} absent"); continue
        na, nb = per_cfg[A]["n"], per_cfg[B]["n"]
        if min(na, nb) < 5:
            print(f"  {app:10s} INCOMPLETE — N={na}/{nb} of 5; not computed on a partial leg"); continue
        ra, rb = per_cfg[A]["runs"], per_cfg[B]["runs"]
        tests = [t for t in sorted(set(ra) & set(rb)) if not t.startswith("_")]
        st = agg.stable_tests(per_cfg, tests)
        # stable_tests returns None both when every subtest is inside the CV bound and when too few are;
        # None means "use them all" either way, but the reason changes what the row is worth, so print it.
        use = tests if st is None else [t for t in tests if t in st]
        why = agg.stable_reason(per_cfg, tests) if st is None else f"{len(use)} of {len(tests)} resolvable"
        pt = agg.geomean([agg.ratio(statistics.median(rb[t]), statistics.median(ra[t]), hib) for t in use])
        lo, hi = agg.bootstrap_geomean_ratio(rb, ra, hib, B=2000, seed=1, only=set(use))
        floor = 100 * max(hi - 1.0, 1.0 - lo)
        verdict = ("peeling FASTER" if lo > 1 else "peeling SLOWER") if (lo > 1 or hi < 1) else "crosses 1.0"
        print(f"  {app:10s} {pt:.4f}  [{lo:.4f}, {hi:.4f}]   {verdict}")
        print(f"             resolution floor ±{floor:.1f}% — an effect smaller than this is invisible here ({why})")
        done.append((app, pt, lo, hi))
    n = len(done); pending = 4 - n
    print(f"\n  {n} of 4 applications complete, {pending} pending "
          f"(MySQL has no AllOpt-peel row and is not in the pair).")
    slower = [d for d in done if d[3] < 1]; faster = [d for d in done if d[2] > 1]
    # A branch is called only when the PENDING applications cannot change it -- not merely when three rows
    # exist. Those differ: with two slower rows and one pending, three-of-four is still reachable and calling
    # C early would pre-empt the rule. Here the reverse holds, and it is worth stating why rather than
    # letting a threshold on the row count stand in for the argument.
    a_reachable = len(slower) + pending >= 3
    b_reachable = len(faster) + pending >= 3
    if n < 4 and (a_reachable or b_reachable):
        print(f"  NOT YET DETERMINED: {len(slower)} slower, {len(faster)} faster, {pending} pending — "
              f"{'A' if a_reachable else ''}{'/' if a_reachable and b_reachable else ''}"
              f"{'B' if b_reachable else ''} still reachable. No branch is called.")
        return
    if len(slower) >= 3:   print("  BRANCH A: peeling does not pay; executed-access work is NOT licensed.")
    elif len(faster) >= 3: print("  BRANCH B: peeling pays; the static increase is a description problem only.")
    else:
        print("  BRANCH C: mixed or crossing — the executed-access pair is worth its cost.")
        if n < 4:
            print(f"  Determined with {pending} application(s) still pending: {len(slower)} slower and "
                  f"{len(faster)} faster of {n}, so neither A nor B can reach 3 of 4 whatever the rest do.")
    print("  Per-application rows above are reported whichever branch fires, per the registration:")
    print("  a counting rule cannot distinguish a global null from a genuine split.")

main()
