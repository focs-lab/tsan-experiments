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

# --topology <cpuset>: the SHAPE of the set, printed as "n_physical n_complete_pairs n_logical".
# Equal logical counts are not equal machines: the campaign's 48 was 24 physical cores with BOTH SMT
# siblings of each, while 48 contiguous processors on this host would be 48 separate cores with none of
# their siblings -- twice the compute and no sibling contention. A row measured on one cannot be compared
# with an interval measured on the other, and nothing recorded the difference. (2026-09-20.)
if len(sys.argv) > 2 and sys.argv[1] == "--topology":
    want = expand(sys.argv[2]) if sys.argv[2].strip() else None
    import os as _os
    if want is None:                      # unpinned: the whole machine
        want = {int(d[3:]) for d in _os.listdir("/sys/devices/system/cpu")
                if d.startswith("cpu") and d[3:].isdigit()}
    cores, complete = set(), 0
    for c in sorted(want):
        f = f"/sys/devices/system/cpu/cpu{c}/topology/thread_siblings_list"
        try: sib = open(f).read().strip()
        except OSError: continue
        if sib in cores: continue
        cores.add(sib)
        if all(int(x) in want for x in expand(sib)): complete += 1
    print(len(cores), complete, len(want))
    raise SystemExit(0)

inside = expand(sys.argv[1])
# AN EMPTY CPUSET IS "UNPINNED", NOT "EVERY CPU IS FOREIGN". With no pinned set the benchmark runs
# everywhere, so there is no region where nothing of ours can run and no foreign signal to read. Treating
# the empty set literally put every CPU on the outside, and the outside busy share then measured OUR OWN
# workload: on a machine small enough for the benchmark to fill it, every run exceeded the threshold, was
# re-run once, failed again, and the leg produced no data after paying twice for it. Everything inside and
# nothing outside is what docs/confounds.md already describes -- outside_busy_share null, gate_checked
# false -- and it is what the downstream `if n_outside > 0` tests were written for.
ALL_INSIDE = not sys.argv[1].strip()
# CPUs deliberately given to our own background work (a long compile parked off the benchmark set) are
# neither "ours" for this run nor foreign disturbance: excluded from both sides so the outside busy share
# keeps measuring other people's load.  Source: $P5_IGNORE_CPUS, else the file "ignore_cpus" next to this
# script, else nothing.
import os
ig = os.environ.get("P5_IGNORE_CPUS")
if ig is None:
    f = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ignore_cpus")
    # Comments and blank lines are stripped, so the shipped file can explain itself and still default to
    # EMPTY. It used to ship this lab's reserved processors (52-55,108-111) as the default, which on an
    # evaluator's machine silently removed eight processors from the disturbance accounting -- the gate
    # quietly not watching part of the machine it was asked to watch. (Audit, 2026-09-19.)
    ig = ""
    if os.path.exists(f):
        ig = ",".join(l.split("#", 1)[0].strip() for l in open(f) if l.split("#", 1)[0].strip())
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
    if ALL_INSIDE or n in inside: bi += busy; ni += 1
    else: bo += busy; no += 1
print(bi, bo, ni, no)
