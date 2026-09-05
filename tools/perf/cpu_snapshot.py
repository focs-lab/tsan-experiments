#!/usr/bin/env python3
"""cpu_snapshot.py <cpuset> — busy jiffies inside and outside the cpuset, plus the two CPU counts.

Prints "inside_busy outside_busy n_inside n_outside".  Busy = all /proc/stat fields except idle and iowait.
The benchmark is pinned to the cpuset, so nothing of ours ever runs outside it: the busy time on the outside
CPUs is foreign by construction and is the disturbance signal, independent of how well we account for our own
processes (a server started outside the timed region, a benchmark that daemonises, ...).
"""
import sys

def expand(s):
    out = set()
    for part in s.split(","):
        if "-" in part:
            a, b = part.split("-"); out.update(range(int(a), int(b) + 1))
        elif part:
            out.add(int(part))
    return out

inside = expand(sys.argv[1])
# CPUs deliberately given to our own background work (a long compile parked off the benchmark set) are
# neither "ours" for this run nor foreign disturbance: excluded from both sides so the outside busy share
# keeps measuring other people's load.  Source: $P5_IGNORE_CPUS, else the file "ignore_cpus" next to this
# script, else nothing.
import os
ig = os.environ.get("P5_IGNORE_CPUS")
if ig is None:
    f = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ignore_cpus")
    ig = open(f).read().strip() if os.path.exists(f) else ""
ignored = expand(ig) if ig else set()
inside -= ignored
bi = bo = ni = no = 0
for line in open("/proc/stat"):
    f = line.split()
    if not f[0].startswith("cpu") or f[0] == "cpu":
        continue
    n = int(f[0][3:]); v = [int(x) for x in f[1:]]
    busy = v[0] + v[1] + v[2] + sum(v[5:])          # user+nice+system+irq+softirq+steal+guest*; skip idle, iowait
    if n in ignored: continue
    if n in inside: bi += busy; ni += 1
    else: bo += busy; no += 1
print(bi, bo, ni, no)
