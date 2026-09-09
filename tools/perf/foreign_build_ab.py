#!/usr/bin/env python3
"""foreign_build_ab.py <results-root> <start-iso> [end-iso] — did a neighbouring lane's build move our numbers?

Splits every run of every application into "during" and "outside" the given window by its recorded start time,
compares each run with the median of the same configuration's runs outside the window, and reports the two
groups. Same-configuration comparison, so configuration effects cancel; the only systematic term left is the
window. Prints the foreign-activity share of both groups as the exposure that is being tested.
"""
import sys, os, json, glob, statistics as st
from datetime import datetime
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aggregate as A

def when(s):
    """meta.json records start/end as epoch seconds; the window is given as an ISO string."""
    if isinstance(s, (int, float)):
        return datetime.fromtimestamp(s).astimezone()
    return datetime.fromisoformat(s)

def main():
    root, start = sys.argv[1], when(sys.argv[2])
    end = when(sys.argv[3]) if len(sys.argv) > 3 else None
    out = []
    for app in ("memcached", "sqlite", "redis", "ffmpeg", "mysql"):
        parser, hib = A.PARSERS[app] if hasattr(A, "PARSERS") else (None, True)
        for cfgdir in sorted(glob.glob(f"{root}/{app}/*")):
            if not os.path.isdir(cfgdir):
                continue
            runs = []
            for d in sorted(glob.glob(cfgdir + "/run[0-9]*")):
                f = d + "/meta.json"
                if not os.path.isfile(f) or any(t in d for t in (".disturbed.", ".stall-", ".foreign-")):
                    continue
                m = json.load(open(f))
                if m.get("rc") != 0:
                    continue
                try:
                    vals = parser(d)
                except Exception:
                    vals = None
                if not vals:
                    continue
                v = st.median([x for x in vals.values() if isinstance(x, (int, float))]) if isinstance(vals, dict) else None
                if v is None:
                    continue
                # A 17-minute run that began before the window still spent most of itself inside it, so
                # classify by overlap, not by start: "during" means the run's own interval intersects it.
                t0, t1 = when(m["start"]), when(m.get("end") or m["start"])
                during = t1 >= start and (end is None or t0 <= end)
                runs.append((during, v, m.get("outside_busy_share", 0.0)))
            base = [r[1] for r in runs if not r[0]]
            if not base or not any(r[0] for r in runs):
                continue
            med = st.median(base)
            for during, v, o in runs:
                rel = v / med if hib else med / v          # >1 means faster than the outside-window median
                out.append((app, os.path.basename(cfgdir), during, rel, o))
    if not out:
        print("no configuration has runs on both sides of the window yet")
        return
    print(f"{'app':10s} {'group':8s} {'runs':>5s} {'median relative metric':>24s} {'median outside-busy':>21s}")
    for app in sorted({r[0] for r in out}) + ["ALL"]:
        for during in (True, False):
            sub = [r for r in out if (app == "ALL" or r[0] == app) and r[2] is during]
            if not sub:
                continue
            print(f"{app:10s} {'during' if during else 'outside':8s} {len(sub):5d} "
                  f"{st.median([r[3] for r in sub]):24.4f} {st.median([r[4] for r in sub]):21.4f}")

main()
