#!/usr/bin/env python3
"""foreign_gate.py [secs]: prints the largest per-process CPU use (cores) over a <secs> window among processes of users other than the leg's own user
(uid 1005 on apollo? - by name), plus that process's user/comm. apollo foreign-user gate (29 Sep 13:2x)."""
import os, sys, time, pwd
me = os.environ.get("USER") or __import__("getpass").getuser(); W = float(sys.argv[1]) if len(sys.argv) > 1 else 10
def snap():
    d = {}
    for p in os.listdir("/proc"):
        if not p.isdigit(): continue
        try:
            st = open(f"/proc/{p}/stat").read().rsplit(")", 1)[1].split(); uid = os.stat(f"/proc/{p}").st_uid
            d[p] = (int(st[11]) + int(st[12]), uid, open(f"/proc/{p}/comm").read().strip())
        except Exception: pass
    return d
a = snap(); time.sleep(W); b = snap(); hz = os.sysconf("SC_CLK_TCK"); best = (0.0, "-", "-")
for p, (t, uid, comm) in b.items():
    if p not in a: continue
    try: user = pwd.getpwuid(uid).pw_name
    except KeyError: user = str(uid)
    if user == me: continue
    c = (t - a[p][0]) / hz / W
    if c > best[0]: best = (c, user, comm)
print(f"{best[0]:.2f} {best[1]} {best[2]}")
