#!/usr/bin/env python3
"""verify_provenance.py <results-root> [...] — assert what every run RECORDED, not what it was told to do.

the standard of 2026-09-16: the proof belongs in the log, not in the intention. A flag passed to a
script, a clip named in an environment variable and a compiler chosen by a hash are all intentions; what a
reviewer can check is the metadata the run wrote down. This checks the artefacts and nothing else, so it can
be run on legs that finished hours ago and on scripts nobody may edit while they are running.

Checks, each one a failure this campaign or its predecessors actually produced:

  compiler_head == the sweep hash        a pre-audit binary was once measured as the current hash (1.48x,
                                         withdrawn); the runner gates on this, so a violation here means
                                         the gate itself was bypassed
  one binary sha256 per configuration    a configuration whose binary changed mid-leg is two populations
                                         reported as one
  input_sha256 present and singular      FF_TEST_VIDEO as a relative path yields runs on the right clip
    (ffmpeg only)                        with an EMPTY hash; two values means two inputs in one row
  one cpuset and one mode per leg        pinned and unpinned runs are not comparable and must not be pooled
  outside_busy_share within the gate     a run above the threshold should have been retired, not kept
  N per configuration                    reports short cells rather than letting a thin row look complete

Exit 0 only when every check passes on every root given.
"""
import json, glob, os, sys
from collections import defaultdict

GATE = 0.10

def rows(root):
    for m in sorted(glob.glob(f"{root}/*/*/run*/meta.json")):
        b = os.path.basename(os.path.dirname(m))
        if not b[3:].isdigit():          # run1.disturbed.*, run2.foreign-window-*, warmup*
            continue
        try: yield json.load(open(m)), m
        except Exception as e: yield {"_broken": str(e)}, m

def check(root, want_hash):
    print(f"\n=== {root} ===")
    runs = list(rows(root))
    if not runs:
        # AN EMPTY ROOT IS NOT A VERIFIED ROOT. This returned True, so a root with nothing in it printed
        # "no measured runs" and then "PROVENANCE OK", exit 0 -- and on 2026-09-18 that is exactly what
        # the artifact's provenance gate said about the freshly exported campaign, because the export
        # writes primary/ and r2/ below the root it was handed and this function looks exactly two levels
        # down. The gate every performance claim rests on was passing on 400 cells it never opened.
        print("  NO MEASURED RUNS UNDER THIS ROOT -- nothing was verified, which is not a pass.")
        print(f"  (looked for {root}/<app>/<config>/run<N>/meta.json; if the runs are a level deeper,")
        print("   name the subdirectories instead, e.g. <root>/primary <root>/r2)")
        return False
    ok = True
    byapp = defaultdict(list)
    for j, m in runs:
        if "_broken" in j:
            print(f"  UNREADABLE {m}: {j['_broken']}"); ok = False; continue
        byapp[j.get("app", "?")].append((j, m))
    for app, rs in sorted(byapp.items()):
        heads   = {r[0].get("compiler_head", "")[:12] for r in rs}
        cpusets = {r[0].get("cpuset") for r in rs}
        modes   = {r[0].get("mode") for r in rs}
        bycfg   = defaultdict(list)
        for j, m in rs: bycfg[j.get("config")].append((j, m))
        bad_hash = heads - {want_hash}
        multi_bin = {c: {x[0].get("sha256") for x in v} for c, v in bycfg.items()}
        multi_bin = {c: s for c, s in multi_bin.items() if len(s) > 1}
        over = [(j.get("config"), os.path.basename(os.path.dirname(m)), j.get("outside_busy_share"))
                for j, m in rs if isinstance(j.get("outside_busy_share"), (int, float))
                and j["outside_busy_share"] > GATE]
        short = {c: len(v) for c, v in bycfg.items() if len(v) < 5}
        print(f"  {app:10s} {len(rs):3d} runs, {len(bycfg):2d} configurations")
        print(f"             compiler_head {'|'.join(sorted(heads))}"
              f"{'   <<< NOT THE SWEEP HASH ' + want_hash if bad_hash else ''}")
        print(f"             cpuset {'|'.join(str(c) for c in sorted(cpusets, key=str))}   "
              f"mode {'|'.join(str(x) for x in sorted(modes, key=str))}"
              f"{'   <<< MIXED, not poolable' if len(cpusets) > 1 or len(modes) > 1 else ''}")
        if app == "ffmpeg":
            shas = {r[0].get("input_sha256", "") for r in rs}
            empty = "" in shas
            print(f"             input_sha256 {'|'.join(sorted(x[:12] or 'EMPTY' for x in shas))}"
                  f"{'   <<< EMPTY: the relative-path trap' if empty else ''}"
                  f"{'   <<< TWO INPUTS IN ONE ROW' if len(shas) > 1 else ''}")
            if empty or len(shas) > 1: ok = False
        # The mixed-cpuset/mode condition was printed but not counted, so a tree with pinned and unpinned
        # runs pooled together reported its own warning and still exited 0 -- a check that reports without
        # failing passes every automated caller. Found by injecting the fault rather than by reading.
        mixed = len(cpusets) > 1 or len(modes) > 1
        if bad_hash or multi_bin or over or short or mixed: ok = False
        for c, s in multi_bin.items():
            print(f"             <<< {c}: {len(s)} DIFFERENT BINARIES across its runs")
        for c, r, v in over[:5]:
            print(f"             <<< {c} {r}: outside_busy {v} > gate {GATE}, kept anyway")
        if short:
            print(f"             short of N=5: " + ", ".join(f"{c}={n}" for c, n in sorted(short.items())))
    return ok

def self_hash(root):
    """The compiler a tree's OWN runs say they were built with, if they agree.

    A tree measured on an earlier compiler is not wrong for failing to be f3deebfbab60 — it is a tree from
    a different campaign, and reporting it as "not the current hash" says nothing a reader can act on. The
    question worth asking of such a tree is whether it is internally consistent: did every run in it use
    one compiler? That is answerable from the tree itself and needs no expectation supplied from outside.
    Returns (hash, True) when every run agrees, (None, False) when they do not or there are none."""
    heads = set()
    for j, _ in rows(root):
        if "_broken" in j: continue
        h = (j.get("compiler_head") or "")[:12]
        if h: heads.add(h)
    return (heads.pop(), True) if len(heads) == 1 else (None, False)

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = [a for a in sys.argv[1:] if a.startswith("--")]
    expect = None
    for f in flags:
        if f.startswith("--expect="): expect = f.split("=", 1)[1][:12]
        elif f == "--expect-self": expect = "self"
        else: sys.exit(f"unknown option {f} (use --expect=<hash> or --expect-self)")
    roots = args or ["results/campaign-f3deebfbab60/primary"]
    if expect is None:
        expect = os.environ.get("P5_HASH", "f3deebfbab60")[:12]
    # A root that holds no runs of its own but has subdirectories that do (the exported layout, which is
    # <root>/primary and <root>/r2) is expanded rather than refused: the caller named the campaign and the
    # campaign is what gets checked. Expansion is only ever one level and only when the root itself is
    # empty, so it cannot silently widen what a caller asked for.
    expanded = []
    for r in roots:
        if not list(rows(r)):
            subs = sorted(d for d in glob.glob(f"{r}/*") if os.path.isdir(d) and list(rows(d)))
            if subs:
                print(f"note: {r} holds no runs directly; checking its {len(subs)} sub-root(s): "
                      + ", ".join(os.path.basename(d) for d in subs))
                expanded.extend(subs); continue
        expanded.append(r)
    roots = expanded
    results = []
    for r in roots:
        if expect == "self":
            h, agreed = self_hash(r)
            if not agreed:
                print(f"\n=== {r} ===\n  runs do not agree on one compiler, so the tree is not internally "
                      f"consistent and no expectation can be derived from it.")
                results.append(False); continue
            print(f"\n[--expect-self] {r}: its own runs agree on {h}; checking the tree against itself.")
            results.append(check(r, h))
        else:
            results.append(check(r, expect))
    allok = all(results)
    label = "each tree against its own compiler" if expect == "self" else f"sweep hash {expect}"
    print(f"\n{'PROVENANCE OK' if allok else 'PROVENANCE PROBLEMS ABOVE'} ({label})")
    return 0 if allok else 1

sys.exit(main())
