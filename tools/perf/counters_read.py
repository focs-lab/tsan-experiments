#!/usr/bin/env python3
"""counters_read.py <run-dir> <app> <config> — read the access-stats counter files for one run.

Conventions agreed before the first run and carried in the frozen copy's CONSOLIDATED_HASH:
  * each line of a file is a RUNNING TOTAL, so take the LAST line of a file, never the sum of its lines;
  * sum ACROSS <path>.<pid> files, since each process's totals genuinely add (FFmpeg runs several encodes);
  * counts are not costs — a fast-path hit and a function entry are not the same number of cycles, so nothing
    here is converted to a share of time.
A run with no files is the caller's problem: it discards rather than recording a zero.
"""
import sys, os, glob, re, json

KEYS = ("total", "fast_hit", "range_calls", "range_bytes", "func_entries")

def last_line_counts(path):
    last = None
    for line in open(path, errors="replace"):
        if "total=" in line:
            last = line
    if last is None:
        return None
    out = {}
    for k in KEYS:
        m = re.search(rf"\b{k}=(\d+)", last)
        if m:
            out[k] = int(m.group(1))
    return out or None

def main():
    d, app, cfg = sys.argv[1], sys.argv[2], sys.argv[3]
    files = sorted(glob.glob(os.path.join(d, "astats.*")))
    per_file, totals = [], dict.fromkeys(KEYS, 0)
    for f in files:
        c = last_line_counts(f)
        if c is None:
            per_file.append({"file": os.path.basename(f), "error": "no counter line"})
            continue
        per_file.append({"file": os.path.basename(f), **c})
        for k in KEYS:
            totals[k] += c.get(k, 0)
    ok = [p for p in per_file if "error" not in p]
    # Fork inheritance: a child that forks after initialisation inherits the parent's counters, so its file
    # repeats totals that sum-across then double-counts — silently, and in the flattering direction. Only MySQL
    # forks here (8 of its 12 files carry byte-identical totals), so the hazard is invisible on four of five
    # applications until one of them forks after doing real work. Identical totals *within one directory* is
    # the signal: two independent processes doing byte-identical work is possible but far less likely.
    seen = {}
    for p in ok:
        seen.setdefault(p.get("total"), []).append(p["file"])
    dup = {t: f for t, f in seen.items() if len(f) > 1 and t}
    if dup:
        out_dup = [{"total": t, "files": f} for t, f in dup.items()]
    else:
        out_dup = []
    out = {"app": app, "config": cfg, "files": len(files), "files_with_counts": len(ok), "totals": totals}
    if out_dup:
        out["warning_identical_totals"] = out_dup
        out["note_fork"] = ("files in this directory report byte-identical totals: likely fork inheritance, "
                            "so the sum across files double-counts by that amount")
    if totals["total"]:
        out["fast_path_hit_rate"] = round(100.0 * totals["fast_hit"] / totals["total"], 4)
        out["func_entries_per_access"] = round(totals["func_entries"] / totals["total"], 4)
    if totals["range_calls"]:
        out["mean_range_bytes"] = round(totals["range_bytes"] / totals["range_calls"], 1)
    out["note"] = ("counts, not costs: these ratios say how often each happens and nothing about where the "
                   "time goes; converting them to a share of time needs a per-call cost this runtime does "
                   "not measure")
    out["per_file"] = per_file
    print(json.dumps(out, indent=1))

main()
