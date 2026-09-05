#!/usr/bin/env python3
"""static_diff.py <results-root-A> <results-root-B> — per (app, config) memory-access site counts A vs B.

The first acceptance check for a new frozen compiler copy: the analyses' verdicts must not move except where
the compiler lane announced a change. Reads static-counts.csv (last entry per key wins) from both roots.
"""
import csv, os, sys
def load(root):
    d = {}
    for r in csv.DictReader(open(os.path.join(root, "static-counts.csv"))):
        d[(r["app"], r["config"])] = (int(r["memory_access_sites"]), r["hash"])
    return d
a, b = load(sys.argv[1]), load(sys.argv[2])
ha = next(iter(a.values()))[1][:12] if a else "?"; hb = next(iter(b.values()))[1][:12] if b else "?"
print(f"| app | config | {ha} | {hb} | delta |"); print("|---|---|---|---|---|")
for k in sorted(set(a) | set(b)):
    x = a.get(k, (None,))[0]; y = b.get(k, (None,))[0]
    d = "" if x is None or y is None else f"{y - x:+d}" + ("" if y == x else f" ({100*(y-x)/x:+.2f} %)" if x else "")
    print(f"| {k[0]} | {k[1]} | {x if x is not None else '-'} | {y if y is not None else '-'} | {d or '-'} |")
