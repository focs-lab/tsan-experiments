#!/usr/bin/env python3
"""percell.py <tag> <app> <aggtree> <base> <view dir> <leg log> [<retired list>]: one line per run: cell, arm, offset, run, composite speed,
ratio to the base arm's mean at that offset, the cell's CCD0 busy and corunner line, retired flag. For checking retired vs kept ratios."""
import sys, os, glob, math, re, importlib.util
tag, app, agg, base, V, LOG = sys.argv[1:7]; RET = set(l.strip() for l in open(sys.argv[7]) if l.strip() and not l.startswith('#')) if len(sys.argv) > 7 else set()
spec = importlib.util.spec_from_file_location("aggregate", os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../perf/aggregate.py"))
A = importlib.util.module_from_spec(spec); sys.modules["aggregate"] = A; spec.loader.exec_module(A); P, hib = A.PARSERS[app]
g = lambda v: math.exp(sum(map(math.log, v)) / len(v))
# CCD0 per (arm, pass) from the leg log, in order
ccd = {}; arm = None; ps = None
for l in open(LOG, errors="replace"):
    m = re.search(r"arm (\S+) pass (\d+)", l)
    if m: arm, ps = m.group(1), int(m.group(2))
    m = re.search(r"ccd0 busy ([0-9.]+)", l)
    if m and arm: ccd[(arm, ps)] = float(m.group(1))
def speed(rd):
    try: r = {t: v for t, v in (P(rd) or {}).items() if not t.startswith("_")}
    except (OSError, ValueError): return None   # cell still running
    return g([v if hib else 1 / v for v in r.values()]) if r else None
rows = []
for c in sorted(os.listdir(V)):
    for rd in sorted(glob.glob(f"{V}/{c}/{app}/*/run[0-9]")):
        s = speed(rd); k = int(rd[-1]); rows.append((c, c[:-2], c[-2:], k, s, os.path.realpath(rd) in RET, ccd.get((c, k))))
bm = {}
for c, a, o, k, s, r, cc in rows:
    if a == base and s and not r: bm.setdefault(o, []).append(s)
bm = {o: sum(v) / len(v) for o, v in bm.items()}
print("cell arm off run speed ratio_to_base_mean ccd0 retired")
for c, a, o, k, s, r, cc in rows:
    print(f"{c} {a} {o} {k} {s:.4g} {s / bm[o]:.3f} {cc if cc is not None else 'na'} {'RETIRED' if r else ''}" if s and o in bm else f"{c} {a} {o} {k} none")
