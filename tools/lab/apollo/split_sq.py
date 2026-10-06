import sys, glob, math, importlib.util, os
spec = importlib.util.spec_from_file_location("aggregate", os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../perf/aggregate.py"))
A = importlib.util.module_from_spec(spec); sys.modules["aggregate"] = A; spec.loader.exec_module(A)
app, D, base = sys.argv[1:4]; codes = sys.argv[4:]; parser, hib = A.PARSERS[app]
g = lambda v: math.exp(sum(map(math.log, v))/len(v))
def cell(c,k):
    out={}
    for rd in glob.glob(f"{D}/{c}{k}/{app}/*/run[0-9]"):
        for t,v in (parser(rd) or {}).items():
            if not t.startswith("_"): out.setdefault(t,[]).append(v if hib else 1/v)
    return {t:sum(v)/len(v) for t,v in out.items()}
K=["00","16","32","48"]; B={k:cell(base,k) for k in K}
for c in codes:
    C={k:cell(c,k) for k in K}; ts=sorted(set().union(*[set(B[k]) for k in K]))
    print(c, "over", base+":", "  ".join(f"{t} {g([C[k][t]/B[k][t] for k in K if t in C[k] and t in B[k]]):.3f}" for t in ts))
