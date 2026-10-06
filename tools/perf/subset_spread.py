#!/usr/bin/env python3
"""subset_spread.py — what would this row have read at a smaller N?

    subset_spread.py <results-root> <app> <config> [--baseline tsan] [--size 2] [--interval LO HI]

Recomputes the headline statistic over every subset of the runs of a completed leg, using aggregate.py's
own geomean and ratio so the numbers are the same estimator the tables print, not an approximation.

WHY IT EXISTS. An evaluator's default is N = 2 and the artifact's intervals are N = 5. When an N = 2 point
falls outside an interval, the question is whether that is a disagreement or the spread of a two-run
estimate -- and the answer is computable from a leg already on disk, without measuring anything. On the
SQLite AllOpt-with-peeling row, three of the ten two-run subsets of a clean N = 5 leg exceed the shipped
upper bound while the N = 5 answer sits inside it; on the Redis DynSTC row the subsets span a range that
the observed N = 2 points lie above, which is the opposite finding and rules the spread out as the cause.

The subsets share runs and come from one session, so this measures WITHIN-session variability only.
Between-session drift is additional and is not visible here; do not read the spread as a confidence
interval, and do not read "k of n subsets outside" as a probability.
"""
import argparse, importlib.util, itertools, os, statistics as st, sys

def load_agg():
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("agg", os.path.join(here, "aggregate.py"))
    m = importlib.util.module_from_spec(spec); sys.modules["agg"] = m; spec.loader.exec_module(m)
    return m

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root"); ap.add_argument("app"); ap.add_argument("config")
    ap.add_argument("--baseline", default="tsan")
    ap.add_argument("--size", type=int, default=2, help="subset size (default 2, the evaluator's default N)")
    ap.add_argument("--interval", nargs=2, type=float, metavar=("LO", "HI"),
                    help="count subsets falling outside this interval")
    a = ap.parse_args()
    agg = load_agg()
    per_cfg, hib = agg.collect(a.root, a.app, None)
    for c in (a.baseline, a.config):
        if c not in per_cfg:
            sys.exit(f"{c!r} not among configurations in {a.root}: {sorted(per_cfg)}")
    tests = [t for t in per_cfg[a.baseline]["runs"] if not t.startswith("_")]
    n = min(len(per_cfg[a.baseline]["runs"][t]) for t in tests)
    if n < a.size:
        sys.exit(f"the leg has {n} runs per configuration; cannot take subsets of {a.size}")

    def over(idx):
        return agg.geomean([agg.ratio(st.median([per_cfg[a.config]["runs"][t][i] for i in idx]),
                                      st.median([per_cfg[a.baseline]["runs"][t][i] for i in idx]), hib)
                            for t in tests])

    full = over(range(n))
    subs = sorted(over(p) for p in itertools.combinations(range(n), a.size))
    print(f"{a.app} {a.config} against {a.baseline}, {len(tests)} subtests, {n} runs")
    print(f"  all {n} runs:        {full:.4f}")
    print(f"  {len(subs)} subsets of {a.size}:  " + " ".join(f"{v:.4f}" for v in subs))
    print(f"  min {min(subs):.4f}   median {st.median(subs):.4f}   max {max(subs):.4f}")
    if a.interval:
        lo, hi = a.interval
        out = [v for v in subs if not (lo <= v <= hi)]
        print(f"  outside [{lo}, {hi}]: {len(out)} of {len(subs)}" + (f"  ({', '.join(f'{v:.4f}' for v in out)})" if out else ""))
    print(f"\n  reproduce: subset_spread.py {a.root} {a.app} {a.config}"
          + (f" --interval {a.interval[0]} {a.interval[1]}" if a.interval else ""))
    return 0

if __name__ == "__main__":
    sys.exit(main())
