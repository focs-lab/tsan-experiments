#!/usr/bin/env python3
"""corunner.py <cpulist> <statefile> -> busy share of <cpulist> since the previous call with the same statefile (first call: 'n/a').
Used by the leg runners to log the OTHER half's state around every cell (the pre-registered co-runner rule, 26 Sep)."""
import sys, os, json
def cpus(spec):
    out = set()
    for part in spec.split(","):
        a, _, b = part.partition("-"); out.update(range(int(a), int(b or a) + 1))
    return out
want = cpus(sys.argv[1]); busy = tot = 0
for line in open("/proc/stat"):
    f = line.split()
    if f[0].startswith("cpu") and f[0] != "cpu" and int(f[0][3:]) in want:
        v = list(map(int, f[1:9])); idle = v[3] + v[4]; busy += sum(v) - idle; tot += sum(v)
prev = None
if os.path.exists(sys.argv[2]):
    try: prev = json.load(open(sys.argv[2]))
    except Exception: prev = None
json.dump({"busy": busy, "tot": tot}, open(sys.argv[2], "w"))
print("n/a" if not prev or tot <= prev["tot"] else f"{(busy - prev['busy']) / (tot - prev['tot']):.3f}")
