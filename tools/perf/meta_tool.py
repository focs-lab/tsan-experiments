#!/usr/bin/env python3
"""meta_tool.py mark <meta.json> <foreign_max> | is-disturbed <meta.json> | is-done <meta.json>"""
import json, sys
op, p = sys.argv[1], sys.argv[2]
try: m = json.load(open(p))
except Exception: sys.exit(0 if op == "is-disturbed" else 1)
if op == "mark":
    m["disturbed"] = bool(m.get("rc", 1) != 0 or m.get("foreign_cpu_share", 0) > float(sys.argv[3]))
    json.dump(m, open(p, "w"), indent=1); print("DISTURBED" if m["disturbed"] else "ok")
elif op == "is-disturbed": sys.exit(0 if m.get("disturbed") else 1)
elif op == "is-done": sys.exit(0 if m.get("rc") == 0 and not m.get("disturbed") else 1)
