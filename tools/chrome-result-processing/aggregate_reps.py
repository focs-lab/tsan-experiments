#!/usr/bin/env python3
"""aggregate_reps.py — fold N Telemetry repetitions into the per-suite CSV schema the CDF tooling reads.

Input:  <results-root>/<suite>/rep<k>/results.csv (Telemetry CSV: name,unit,avg,count,max,min,std,sum,...,displayLabel,...)
Output: <out-dir>/<suite>_results.csv with the same columns, where avg = median over reps of the per-rep avg,
        min/max = over reps, std = sample std over reps, count = number of reps; one row per (story, label).
Only rows whose unit is a time or score metric are kept (same rule as csv/parse.py: unit 'ms' is lower-is-better,
'score' higher-is-better). generate_cdf_latex.py / generate_overall_cdf_latex.py then run unchanged.
"""
import argparse, csv, glob, os, statistics as st, collections
ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("root"); ap.add_argument("--out", default=None); ap.add_argument("--units", default="ms,score,unitless")
a = ap.parse_args(); out = a.out or os.path.join(a.root, "csv"); os.makedirs(out, exist_ok=True); units = set(a.units.split(","))
for suite in sorted(d for d in os.listdir(a.root) if os.path.isdir(os.path.join(a.root, d, "rep1"))):
    rows = collections.defaultdict(list); header = None
    for f in sorted(glob.glob(os.path.join(a.root, suite, "rep*", "results.csv"))):
        with open(f) as fh:
            r = csv.DictReader(fh); header = header or r.fieldnames
            for row in r:
                if row.get("unit") not in units: continue
                key = (row.get("benchmarks") or row.get("benchmark", ""), row["name"], row.get("displayLabel") or row.get("label", ""))
                try: rows[key].append((float(row["avg"]), row))
                except (KeyError, ValueError): continue
    if not rows: continue
    with open(os.path.join(out, f"{suite}_results.csv"), "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=header); w.writeheader()
        for key, vals in sorted(rows.items()):
            avgs = [v for v, _ in vals]; row = dict(vals[-1][1])
            row.update({"avg": st.median(avgs), "count": len(avgs), "min": min(avgs), "max": max(avgs),
                        "std": st.stdev(avgs) if len(avgs) > 1 else 0.0, "sum": sum(avgs)})
            w.writerow(row)
    print(f"{suite}: {len(rows)} (story,label) rows from {len(set(os.path.dirname(f) for f in glob.glob(os.path.join(a.root, suite, 'rep*', 'results.csv'))))} reps -> {out}/{suite}_results.csv")
