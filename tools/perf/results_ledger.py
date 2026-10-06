#!/usr/bin/env python3
"""results_ledger.py — regenerate the measured tables inside RESULTS.md.

RESULTS.md is the standing record of what each optimisation is worth. Its narrative (what changed, what is
pending, what is unexplained) is written by hand above and below the markers; everything between them is
regenerated from the results trees, so a number in the ledger can never drift from the run that produced it.

    python3 results_ledger.py            # rewrite the tables in RESULTS.md
    python3 results_ledger.py --print    # print them instead

Add a new experiment by adding one entry to TREES. A tree that does not exist yet is listed as pending rather
than silently omitted — an absent row and a null row must not look the same.
"""
import os, re, sys, json, glob, math, importlib.util, statistics as st

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("agg", os.path.join(HERE, "aggregate.py"))
A = importlib.util.module_from_spec(spec); sys.modules["agg"] = A; spec.loader.exec_module(A)

START, END = "<!-- LEDGER-START -->", "<!-- LEDGER-END -->"
APPS = ["memcached", "redis", "sqlite", "ffmpeg", "mysql"]

# Every measured comparison: (label, tree, baseline config, treatment config, compiler, note)
TREES = [
    ("func entry/exit off", "results/nofe-d3bf9f8c39fe", "tsan-sound", "tsan-sound-nofe",
     "d3bf9f8c39fe", "flag already upstream; costs report calling context, not soundness"),
    ("granule merge", "results/merge-timing-afe47a2a75a5", "tsan-sound-nomerge", "tsan-sound",
     "afe47a2a75a5", "conditional on the counters showing executed misses fall"),
]


# Marginal contribution of each SPECIFIC improvement: pairs of configurations differing by exactly one change,
# so the number is what that change adds on top of the configuration below it — not what its whole family is
# worth. (label, tree, base config, config with the improvement, note)
MARGINALS = [
    # each analysis alone, against stock TSan
    ("escape analysis", "results/stageB-d3bf9f8c39fe", "tsan", "tsan-ea", "alone, vs stock"),
    ("lock ownership", "results/stageB-d3bf9f8c39fe", "tsan", "tsan-lo", "alone, vs stock"),
    ("single-threaded (STC)", "results/stageB-d3bf9f8c39fe", "tsan", "tsan-st", "alone, vs stock"),
    ("dynamic single-threaded (DynSTC)", "results/stageB-d3bf9f8c39fe", "tsan", "tsan-stmt", "alone, vs stock"),
    ("SWMR", "results/stageB-d3bf9f8c39fe", "tsan", "tsan-swmr", "alone, vs stock"),
    ("dominance elimination (DE)", "results/stageB-d3bf9f8c39fe", "tsan", "tsan-dom", "alone, vs stock"),
    # what each further improvement adds on top of something else
    ("loop peeling", "results/stageB-d3bf9f8c39fe", "tsan-dom", "tsan-dom_peeling", "added to DE"),
    ("the four sound analyses together", "results/stageB-d3bf9f8c39fe", "tsan", "tsan-sound", "EA+LO+STC+SWMR vs stock"),
    ("DE added to the sound bundle", "results/stageB-d3bf9f8c39fe", "tsan-sound", "tsan-dom-ea-lo-st-swmr", "AllOpt-peel vs sound"),
    ("loop peeling added to AllOpt", "results/stageB-d3bf9f8c39fe", "tsan-dom-ea-lo-st-swmr", "tsan-dom_peeling-ea-lo-st-swmr", ""),
    ("whole-program summaries", "results/stageB-d3bf9f8c39fe", "tsan-sound", "tsan-sound-wp", "added to sound"),
    ("thread-free names", "results/stageB-d3bf9f8c39fe", "tsan-sound", "tsan-sound-tfn", "added to sound; memcached only"),
    ("summaries added to thread-free names", "results/stageB-d3bf9f8c39fe", "tsan-sound-tfn", "tsan-sound-tfn-wp", "memcached only"),
    # the seven yield changes, measured together inside one compiler
    ("yield branch, all seven changes", "results/yield-d98873cda906", "tsan-sound-yoff", "tsan-sound", "on the sound bundle"),
    ("yield branch, on stock", "results/yield-d98873cda906", "tsan-yoff", "tsan", "isolates the interceptor table"),
    ("yield branch, on DynSTC", "results/yield-d98873cda906", "tsan-stmt-yoff", "tsan-stmt", "isolates C1"),
    ("yield branch, on AllOpt+peel", "results/yield-d98873cda906", "tsan-dom_peeling-ea-lo-st-swmr-yoff",
     "tsan-dom_peeling-ea-lo-st-swmr", ""),
    # the runtime lever
    ("shadow-stack maintenance off", "results/nofe-d3bf9f8c39fe", "tsan-sound", "tsan-sound-nofe",
     "added to sound; costs report calling context"),
]

def pct(p):
    """A contribution as a percentage, bolded when its interval excludes zero."""
    if not p:
        return "·"
    v, lo, hi = (p["stable"][0], p["stable"][1], p["stable"][2]) if p["stable"] else (p["su"], p["lo"], p["hi"])
    s = f"{100*(v-1):+.1f}"
    return f"**{s}**" if (lo > 1.0 or hi < 1.0) else s

def load(root, apps=APPS):
    out = {}
    for app in apps:
        p = os.path.join(HERE, root, f"perf_{app}.json")
        if os.path.exists(p):
            out[app] = json.load(open(p))
    return out

def pair(per_cfg, app, base, treat, stable_from=None):
    """Speedup of `treat` against `base`, with the interval, using aggregate.py's own statistics."""
    if base not in per_cfg or treat not in per_cfg:
        return None
    hib = A.PARSERS[app][1]
    b, c = per_cfg[base], per_cfg[treat]
    tests = [t for t in b["runs"] if not t.startswith("_") and t in c["runs"]]
    if not tests:
        return None
    rs = {t: A.ratio(st.median(c["runs"][t]), st.median(b["runs"][t]), hib) for t in tests}
    lo, hi = A.bootstrap_geomean_ratio(c["runs"], b["runs"], hib)
    out = {"n": min(b["n"], c["n"]), "su": A.geomean(rs.values()), "lo": lo, "hi": hi, "stable": None}
    # the resolvable-subtest set is a property of the workload, so take it from the campaign tree where many
    # configurations determined it rather than from a two-configuration tree where the estimator cannot run
    if stable_from and app in stable_from:
        ref = stable_from[app]
        rtests = [t for t in ref["tsan"]["runs"] if not t.startswith("_")] if "tsan" in ref else []
        keep = A.stable_tests(ref, rtests) if rtests else None
        if keep and len(keep) < len(tests):
            sl, sh = A.bootstrap_geomean_ratio(c["runs"], b["runs"], hib, only=keep)
            out["stable"] = (A.geomean([v for t, v in rs.items() if t in keep]), sl, sh, len(keep), len(tests))
    return out

def fmt(p, key="su"):
    if not p:
        return "—"
    if key == "stable" and p["stable"]:
        v, lo, hi, k, n = p["stable"]
        return f"**{v:.3f}** [{lo:.3f}, {hi:.3f}] ({k}/{n})" if (lo > 1 or hi < 1) else f"{v:.3f} [{lo:.3f}, {hi:.3f}] ({k}/{n})"
    if key == "stable":
        return "—"
    conclusive = p["lo"] > 1.0 or p["hi"] < 1.0
    s = f"{p['su']:.3f} [{p['lo']:.3f}, {p['hi']:.3f}]"
    return f"**{s}**" if conclusive else s

def verdict(p):
    if not p:
        return "not measured"
    use = p["stable"] if p["stable"] else (p["su"], p["lo"], p["hi"])
    v, lo, hi = use[0], use[1], use[2]
    if lo > 1.0:
        return f"gain {100*(v-1):+.1f} %"
    if hi < 1.0:
        return f"LOSS {100*(v-1):+.1f} %"
    return "not resolved"

def campaign_best(stageb):
    """The best analysis-based result the campaign ever measured, as the bar everything else is judged against."""
    best = []
    for app in APPS:
        if app not in stageb:
            continue
        hib = A.PARSERS[app][1]
        per = stageb[app]
        if "tsan" not in per:
            continue
        tests = [t for t in per["tsan"]["runs"] if not t.startswith("_")]
        keep = A.stable_tests(per, tests)
        for cfg, info in per.items():
            if cfg in ("tsan", "orig") or "STALE" in cfg:
                continue
            shared = [t for t in tests if t in info["runs"]]
            if not shared:
                continue
            lo, hi = A.bootstrap_geomean_ratio(info["runs"], per["tsan"]["runs"], hib)
            rs = {t: A.ratio(st.median(info["runs"][t]), st.median(per["tsan"]["runs"][t]), hib) for t in shared}
            g = A.geomean(rs.values())
            conclusive = lo > 1.0
            if keep and not conclusive:
                sl, sh = A.bootstrap_geomean_ratio(info["runs"], per["tsan"]["runs"], hib, only=keep)
                if sl > 1.0:
                    g, lo, hi, conclusive = A.geomean([v for t, v in rs.items() if t in keep]), sl, sh, True
            if conclusive:
                best.append((g, app, A.label(cfg), lo, hi))
    best.sort(reverse=True)
    return best


# ---------------------------------------------------------------- dynamic reach
# Counter trees, each tagged with the compiler copy it was measured against. Two of these share a copy and one
# does not, and the distinction matters: a "repeat" across copies is not a repeat, it is a compiler difference
# plus noise. Every comparison below is therefore taken inside one copy, and the repeatability floor is
# estimated only from configurations measured twice inside the SAME copy.
COUNTER_TREES = [
    ("results/profile-2026-09-09-counters", "1391bf330765"),
    ("results/merge-counters", "afe47a2a75a5"),
    ("results/combo-counters", "afe47a2a75a5"),
]

# How a cell is made comparable across configurations. Fixed-work workloads (a fixed request or frame count)
# can be compared on raw totals; SQLite's threadtest3 subtests run for a fixed *time*, so a faster build
# completes more iterations and its raw total is meaningless — it is normalised per iteration. MySQL's leg is
# sampled for a fixed number of seconds with no completed-transaction count in the counter run, so it cannot be
# normalised at all and is left out rather than silently compared.
FIXED_WORK = {"memcached": "fixed request count", "redis": "fixed request count", "ffmpeg": "fixed frame count"}

DYN_PAIRS = [
    ("granule merge", "tsan-sound-nomerge", "tsan-sound", "on the sound bundle"),
    ("granule merge", "tsan-dom-ea-lo-st-swmr-nomerge", "tsan-dom-ea-lo-st-swmr", "on AllOpt-peel"),
    ("granule merge", "tsan-dom_peeling-ea-lo-st-swmr-nomerge", "tsan-dom_peeling-ea-lo-st-swmr", "on AllOpt+peel"),
    ("loop peeling", "tsan-dom-ea-lo-st-swmr", "tsan-dom_peeling-ea-lo-st-swmr", "on AllOpt, merge on"),
    ("loop peeling", "tsan-dom-ea-lo-st-swmr-nomerge", "tsan-dom_peeling-ea-lo-st-swmr-nomerge", "on AllOpt, merge off"),
    ("whole-program summaries", "tsan-sound", "tsan-sound-wp", "on the sound bundle"),
    ("dominance elimination (DE)", "tsan", "tsan-dom", "alone, vs stock"),
    ("the four sound analyses", "tsan", "tsan-sound", "EA+LO+STC+SWMR vs stock"),
    ("AllOpt+peel", "tsan", "tsan-dom_peeling-ea-lo-st-swmr", "the whole bundle vs stock"),
]

def _iters(d):
    """threadtest3 prints one line per worker; the run is fixed-time, so iterations are the unit of work."""
    try:
        v = [int(m) for m in re.findall(r"says:\s+(\d+) iterations", open(os.path.join(d, "run.log")).read())]
    except OSError:
        return None
    return sum(v) or None

def counter_cells():
    """{(compiler, app, config): [normalised accesses, one per tree]} — repeats kept rather than averaged
    away, because the spread between two runs of one configuration is the only noise estimate this leg has."""
    cells = {}
    for tree, compiler in COUNTER_TREES:
        for f in sorted(glob.glob(os.path.join(HERE, tree, "*", "*", "summary.json"))):
            try:
                j = json.load(open(f))
            except (OSError, ValueError):
                continue
            if "error" in j:
                continue
            app, cfg, tot, d = j["app"], j["config"], j["totals"]["total"], os.path.dirname(f)
            if app == "sqlite":
                n = _iters(d)
                if not n:
                    continue
                tot = tot / n
            elif app not in FIXED_WORK:
                continue                      # mysql: fixed-time leg with no work count, not comparable
            cells.setdefault((compiler, app, cfg), []).append(tot)
    return cells

def dynamic_reach():
    cells = counter_cells()
    if not cells:
        return ""
    # noise floor per application, from same-copy repeats only
    floor = {}
    for (_, app, _), v in cells.items():
        if len(v) > 1:
            floor.setdefault(app, []).append(100 * (max(v) - min(v)) / min(v))
    floor = {a: max(v) for a, v in floor.items()}
    L = ["### Dynamic reach — what each improvement removes from the executed accesses\n",
         "The mechanism behind the speedups above, and a different quantity from them: the change in executed "
         "access callbacks, one run per cell, negative meaning fewer. Every pair is taken inside one compiler "
         "copy. SQLite is normalised per threadtest3 iteration because its subtests run for a fixed time and a "
         "faster build simply completes more of them; the other applications do a fixed amount of work, so "
         "their raw totals compare directly. MySQL's counter leg is sampled for a fixed number of seconds with "
         "no completed-transaction count, so it cannot be normalised and is left out rather than compared "
         "wrongly.\n"]
    if floor:
        L.append("**Repeatability floor**, from the configurations measured twice inside the same compiler copy: "
                 + "; ".join(f"{a} {v:.2f} %" for a, v in sorted(floor.items()))
                 + ". A cell smaller than its application's floor is not a measurement of that improvement and "
                   "is shown in parentheses; an application with no repeat of its own borrows the largest floor "
                   "measured, which is the conservative choice. A floor read off a single pair of runs is "
                   "itself optimistic: it is the smallest spread two runs happened to show, not the spread "
                   "of the cell.\n")
    borrowed = max(floor.values()) if floor else 0.0
    apps = [a for a in APPS if any(k[1] == a for k in cells)]
    L.append("| improvement | note | copy | " + " | ".join(apps) + " |")
    L.append("|---|---|---|" + "---|" * len(apps))
    for label, base, treat, note in DYN_PAIRS:
        for _, compiler in COUNTER_TREES:
            row, seen = [], False
            for app in apps:
                b, c = cells.get((compiler, app, base)), cells.get((compiler, app, treat))
                if not b or not c:
                    row.append("·"); continue
                seen = True
                ch = 100 * (st.median(c) / st.median(b) - 1)
                f = floor.get(app, borrowed)
                row.append(f"({ch:+.2f})" if abs(ch) < f else f"**{ch:+.2f}**")
            if seen:
                L.append(f"| {label} | {note} | `{compiler}` | " + " | ".join(row) + " |")
                break
    L.append("")
    return "\n".join(L)

def build():
    L = []
    stageb = load("results/stageB-d3bf9f8c39fe")

    L.append("### Scoreboard — what each lever is worth\n")
    L.append("Speedup against the same configuration without the lever, geometric mean over the application's "
             "tests, 95 % bootstrap interval, N = 5. **Bold** means the interval excludes 1.0. A blank cell is "
             "not measured; \"not resolved\" is a null, not a zero — the effect is below that application's "
             "resolution, which is 12.2 points on memcached and 14.1 on MySQL.\n")
    for label, tree, base, treat, compiler, note in TREES:
        if not os.path.isdir(os.path.join(HERE, tree)):
            L.append(f"**{label}** — *pending* (`{tree}` does not exist yet). {note}\n")
            continue
        per = load(tree)
        L.append(f"**{label}** · compiler `{compiler}` · `{tree}`  \n*{note}*\n")
        L.append("| application | speedup | resolvable subtests | verdict |")
        L.append("|---|---|---|---|")
        rows = []
        for app in APPS:
            if app not in per:
                continue
            p = pair(per[app], app, base, treat, stable_from=stageb)
            if p:
                rows.append((p["stable"][0] if p["stable"] else p["su"], app, p))
        for _, app, p in sorted(rows, reverse=True):
            L.append(f"| {app} | {fmt(p)} | {fmt(p, 'stable')} | {verdict(p)} |")
        L.append("")

    L.append("### Contribution of each specific improvement\n")
    L.append("Percentage change in speed that **this one change** adds on top of the configuration named in the "
             "note — not what its family is worth. Each pair differs by exactly one improvement, measured in the "
             "same tree with the same N. **Bold** means the interval excludes zero; a plain number is inside the "
             "noise; `·` means that configuration does not exist for that application. Where an application has "
             "a resolvable-subtest set, the figure uses it.\n")
    L.append("| improvement | note | memcached | redis | sqlite | ffmpeg | mysql |")
    L.append("|---|---|---|---|---|---|---|")
    for label, tree, base, treat, note in MARGINALS:
        if not os.path.isdir(os.path.join(HERE, tree)):
            L.append(f"| {label} | *pending* | · | · | · | · | · |")
            continue
        per = load(tree)
        cells = []
        for app in APPS:
            p = pair(per[app], app, base, treat, stable_from=stageb) if app in per else None
            cells.append(pct(p))
        L.append(f"| {label} | {note} | " + " | ".join(cells) + " |")
    L.append("")

    L.append("### The bar: best analysis-based result in the campaign\n")
    L.append("Every configuration of the paper's set, five applications, 58 rows with a speedup "
             "(`results/stageB-d3bf9f8c39fe`). Only these separate from stock TSan.\n")
    L.append("| application | configuration | speedup |")
    L.append("|---|---|---|")
    for g, app, lab, lo, hi in campaign_best(stageb):
        L.append(f"| {app} | `{lab}` | {g:.3f} [{lo:.3f}, {hi:.3f}] |")
    L.append("")

    L.append("### Where the instrumented cycles go\n")
    prof = os.path.join(HERE, "results/profile-2026-09-09")
    if os.path.isdir(prof):
        L.append("Share of instrumented cycles by callback class, sound configuration, one sampled run per "
                 "cell. The shadow-stack column is the lever above. **sync / clocks** is `SlotLock`, `Release`, "
                 "`MetaMap::GetSync`, `VectorClock` and the mutex interceptors — the release machinery, which "
                 "no analysis in the campaign touches and which dominates two applications. These figures were "
                 "wrong until 2026-09-10: perf demangles C++ frames, and the classifier matched only the "
                 "`__tsan_` C prefix, so every `__tsan::` frame was binned as application — 58 % of memcached's "
                 "cycles.\n")
        L.append("| application | cycles in TSan | access callbacks | shadow stack | sync / clocks | range | other |")
        L.append("|---|---|---|---|---|---|---|")
        for app in APPS:
            f = os.path.join(prof, app, "tsan-sound", "summary.json")
            if not os.path.exists(f):
                continue
            j = json.load(open(f)); s = j["share_of_instrumented"]
            L.append(f"| {app} | {j['cycles_in_tsan_pct']:.1f} % | {s['access']:.1f} % | "
                     f"**{s['shadow_stack']:.1f} %** | {s.get('sync', 0):.1f} % | {s.get('range', 0):.1f} % | "
                     f"{s['tsan_other'] + s['atomic']:.1f} % |")
        L.append("")

    L.append(dynamic_reach())

    L.append("### Executed-access counters\n")
    cnt = os.path.join(HERE, "results/profile-2026-09-09-counters")
    if os.path.isdir(cnt):
        L.append("Counts, not costs — a fast-path hit and a function entry are not the same number of cycles. "
                 "A miss costs about 19.6 cycles and a hit 5.8 (measured, lower bound).\n")
        L.append("| application | executed accesses | fast-path hits | func entries / access | mean range bytes |")
        L.append("|---|---|---|---|---|")
        for app in APPS:
            f = os.path.join(cnt, app, "tsan-sound", "summary.json")
            if not os.path.exists(f):
                continue
            j = json.load(open(f)); t = j["totals"]
            L.append(f"| {app} | {t['total']:,} | {j.get('fast_path_hit_rate', 0):.1f} % | "
                     f"{j.get('func_entries_per_access', 0):.3f} | {j.get('mean_range_bytes', 0):.0f} |")
        L.append("")
    return "\n".join(L) + "\n"

def main():
    block = build()
    if "--print" in sys.argv:
        print(block); return
    p = os.path.join(HERE, "RESULTS.md")
    t = open(p).read()
    if START in t and END in t:
        t = t[:t.index(START) + len(START)] + "\n\n" + block + "\n" + t[t.index(END):]
    else:
        t = t.rstrip() + "\n\n" + START + "\n\n" + block + "\n" + END + "\n"
    open(p, "w").write(t)
    print(f"RESULTS.md tables regenerated ({len(block.splitlines())} lines)")

main()
