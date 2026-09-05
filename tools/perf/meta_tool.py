#!/usr/bin/env python3
"""meta_tool.py mark <meta.json> <foreign_max> | is-disturbed <meta.json> | is-done <meta.json>"""
import json, sys
op, p = sys.argv[1], sys.argv[2]
try: m = json.load(open(p))
except Exception: sys.exit(0 if op == "is-disturbed" else 1)
if op == "mark":
    # Disturbance = foreign CPU activity, measured on the CPUs outside our pinned set, where nothing of
# ours can run.  (foreign_cpu_share depends on process accounting and undercounts servers we start
# outside the timed region; it stays in the record but no longer decides.)
    m["disturbed"] = bool(m.get("rc", 1) != 0 or m.get("outside_busy_share", m.get("foreign_cpu_share", 0)) > float(sys.argv[3]))
    json.dump(m, open(p, "w"), indent=1); print("DISTURBED" if m["disturbed"] else "ok")
elif op == "is-disturbed": sys.exit(0 if m.get("disturbed") else 1)
elif op == "is-done": sys.exit(0 if m.get("rc") == 0 and not m.get("disturbed") else 1)
