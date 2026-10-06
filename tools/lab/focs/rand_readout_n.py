#!/usr/bin/env python3
"""rand_readout_n.py <app> <view dir> <base> <code>... [--pair A/B ...]: randomised legs with N>1 per arm-offset. Per cell and run k: composite speed
(geomean over workloads). Per offset: ratio of the arm's mean to the base's mean over runs; paired per run k (same pass). Pairs --pair X/Y give Y/X
per offset per run (12 pairs at 4 offsets x N=3) with geomean and min-max. Retired (COV_RETIRED) runs skipped."""
import sys, os, glob, math, importlib.util
spec = importlib.util.spec_from_file_location("aggregate", os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../perf/aggregate.py"))
A = importlib.util.module_from_spec(spec); sys.modules["aggregate"] = A; spec.loader.exec_module(A)
args=[a for a in sys.argv[1:] if not a.startswith("--pair") ]; pairs=[a.split("=",1)[1] for a in sys.argv[1:] if a.startswith("--pair=")]
app, D, base = args[:3]; codes = args[3:]; parser, hib = A.PARSERS[app]
ret = set(l.strip() for l in open(os.environ["COV_RETIRED"]) if l.strip() and not l.startswith("#")) if os.environ.get("COV_RETIRED") else set()
g = lambda v: math.exp(sum(map(math.log, v)) / len(v))
K=[0,16,32,48]
def runs(code,k):
    out={}
    for rd in glob.glob(f"{D}/{code}{k:02d}/{app}/*/run[0-9]"):
        if os.path.realpath(rd) in ret: continue
        r = parser(rd); r = {t:v for t,v in (r or {}).items() if not t.startswith("_")}
        if r: out[int(rd[-1])] = g([v if hib else 1/v for v in r.values()])
    return out
R={c:{k:runs(c,k) for k in K} for c in [base]+codes}
print(f"{app}: base {base}; composite = geomean over workloads; per offset ratio of mean speeds; runs per cell {sorted(set(len(v) for c in R for v in R[c].values()))}")
for c in codes:
    per={k: (sum(R[c][k].values())/len(R[c][k]))/(sum(R[base][k].values())/len(R[base][k])) for k in K if R[c][k] and R[base][k]}
    print(f"  {c:4s} over {base}: {g(list(per.values())):.3f} (" + " ".join(f"{k}:{v:.3f}" for k,v in per.items()) + ")")
for p in pairs:
    x,y=p.split("/")
    rr=[R[y][k][n]/R[x][k][n] for k in K for n in R[y][k] if n in R[x][k]]
    print(f"  pair {y}/{x}: {len(rr)} paired runs, geomean {g(rr):.3f}, min {min(rr):.3f}, max {max(rr):.3f}")
