#!/usr/bin/env python3
"""static_diff.py <old-tree> <new-tree> — compare static instrumentation counts between two campaign trees.

Written before the new tree's numbers existed, so the reading is fixed in advance rather than chosen to suit
what came out. The three-way classification and its order of checks come from the fail-closed direction of the
escape analysis, not from taste:

  IDENTICAL  the ONLY green. The compile-time series is claimed verdict-identical, and 112 corpus rows, the
             sqlite3.c counter signature and MySQL's 640 355 sites all say so.
  LOWER      stop that application and report it with the translation-unit list; its legs wait. The
             fail-closed direction of the analysis says a difference COULD only point this way — an
             unresolved operand makes things escaped, so newly-resolved operands can only reduce escaping —
             but that establishes the direction a departure would take, NOT that any particular departure is
             sound. A departure from a verdict-identity claim is a departure whichever way it points, and it
             is the compiler lane's to explain rather than this lane's to accept. (Superseding an earlier
             reading here that treated LOWER as good news on sight; corrected 2026-09-15.)
  HIGHER     stop everything. Nothing in this series should increase instrumentation.

ORDER OF CHECKS MATTERS AND IS THE POINT. A fired budget also changes instrumentation — upward, because
abandoning is the fail-closed path — so a translation unit could do BOTH at once and net out lower, reading as
the good outcome while hiding the bad one. So the abandoned count is checked FIRST and a non-zero count
disqualifies the row from any reading at all, whichever direction it moved.
"""
import csv, os, re, sys

def counts(tree):
    p = os.path.join(tree, "static-counts.csv")
    out = {}
    if not os.path.exists(p):
        return out
    for r in csv.DictReader(open(p)):
        try:
            out[(r["app"], r["config"])] = (int(r["memory_access_sites"]), int(r["tsan_calls_total"]))
        except (KeyError, ValueError):
            continue
    return out

def abandoned(tree):
    """Per application, from the build logs. The warning goes to stderr and carries the function name."""
    out = {}
    for f in sorted(os.listdir(tree)) if os.path.isdir(tree) else []:
        m = re.fullmatch(r"build-(\w+)\.log", f)
        if not m:
            continue
        txt = open(os.path.join(tree, f), errors="replace").read()
        out[m.group(1)] = txt.count("escape analysis gave up")
    return out

def main():
    old_t, new_t = sys.argv[1], sys.argv[2]
    old, new = counts(old_t), counts(new_t)
    ab = abandoned(new_t)
    shared = sorted(set(old) & set(new))
    print(f"static instrumentation counts: {os.path.basename(old_t)} -> {os.path.basename(new_t)}")
    print(f"{len(shared)} configurations in both trees "
          f"({len(old)} in old, {len(new)} in new — rows absent from either are NOT compared)\n")
    if ab:
        print("abandoned functions per application (non-zero disqualifies that application's rows):")
        for a, n in sorted(ab.items()):
            print(f"  {a:10s} {n}{'   <<< BUDGET FIRED' if n else ''}")
        print()
    buckets = {"identical": [], "lower": [], "higher": [], "disqualified": [], "instrument_failure": []}
    for k in shared:
        app, cfg = k
        o, n = old[k], new[k]
        if ab.get(app, 0) > 0:
            buckets["disqualified"].append((k, o, n)); continue
        # An instrumented configuration with ZERO sites is an instrument failure, not a result — a build that
        # produced nothing, a flag name that silently did nothing, a log the parser could not read. It would
        # otherwise score as the largest possible LOWER, which is the direction we are least suspicious of.
        # (2026-09-15: a mistyped DE flag gave empty output "that a naive differ would have
        # scored as a real difference", and an empty md5 d41d8cd98f00 from an unresolved symlink mount.)
        if cfg != "orig" and (n[0] == 0 or o[0] == 0):
            buckets["instrument_failure"].append((k, o, n)); continue
        if o == n:
            buckets["identical"].append((k, o, n))
        elif n[0] < o[0] or (n[0] == o[0] and n[1] < o[1]):
            buckets["lower"].append((k, o, n))
        else:
            buckets["higher"].append((k, o, n))
    for name in ("identical", "lower", "higher", "disqualified", "instrument_failure"):
        rows = buckets[name]
        if not rows and name in ("disqualified", "instrument_failure"):
            continue
        print(f"{name.upper()}: {len(rows)}")
        if name != "identical":
            for (app, cfg), o, n in rows:
                d = n[0] - o[0]
                print(f"   {app:10s} {cfg:38s} sites {o[0]:7d} -> {n[0]:7d} ({d:+d}), calls {o[1]:8d} -> {n[1]:8d}")
        print()
    if buckets["higher"]:
        print("HIGHER rows exist and nothing in this series should raise instrumentation.")
        print("Check the abandoned count for the specific translation units before any other explanation.")
    if buckets["instrument_failure"]:
        print("ZERO sites on an instrumented configuration is an instrument failure, not a measurement.")
        print("Read the build log for that configuration before treating it as any kind of difference.")
    if buckets["disqualified"]:
        print("Rows disqualified by a non-zero abandoned count are not evidence in either direction:")
        print("a fired budget raises instrumentation and a precision gain lowers it, and one TU can do both.")

main()
