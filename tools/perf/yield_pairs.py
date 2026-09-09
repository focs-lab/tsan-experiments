#!/usr/bin/env python3
"""yield_pairs.py <yield-results-root> — what the seven yield changes are worth, as paired A/B ratios.

Each row is <config> against <config>-yoff: one compiler, one source tree, one build recipe, differing only in
the six -mllvm switches. Anything the stage-b2 base does to the number it does to both halves, so the ratio is
attributable to the yield changes alone (tools/notes/yield-stage-design-2026-09-08.md). Reported the same way
as the main tables: geometric mean over tests on per-test medians, 95 % bootstrap interval over run resamples,
plus the restricted mean over the subtests whose baseline CV is at most 5 %.
"""
import sys, os, json, statistics as st, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("agg", os.path.join(HERE, "aggregate.py"))
A = importlib.util.module_from_spec(spec); sys.modules["agg"] = A; spec.loader.exec_module(A)

def main():
    root = sys.argv[1]
    out = ["# Yield stage: each configuration against its own yield-off build\n",
           "Ratio > 1 means the yield changes are faster. `stable subtests` restricts to the subtests whose "
           "pooled run-to-run CV, taken across every configuration of the application, is at most 5 %; it is "
           "blank where the filter keeps everything or would keep fewer than half.\n",
           "| app | configuration | N on / off | yield on vs off [95 %] | stable subtests [95 %] | sites on / off |"
           , "|---|---|---|---|---|---|"]
    statics = A.static_counts(root)
    for app in ("memcached", "redis", "sqlite", "ffmpeg", "mysql"):
        f = os.path.join(root, f"perf_{app}.json")
        if not os.path.exists(f):
            continue
        hib = A.PARSERS[app][1]
        d = json.load(open(f))
        for cfg in sorted(d):
            off = cfg + "-yoff"
            if off not in d or cfg.endswith("-yoff") or cfg == "orig":
                continue
            on_r, off_r = d[cfg]["runs"], d[off]["runs"]
            tests = [t for t in on_r if t in off_r and not t.startswith("_") and on_r[t] and off_r[t]]
            if not tests:
                continue
            rs = {t: A.ratio(st.median(on_r[t]), st.median(off_r[t]), hib) for t in tests}
            lo, hi = A.bootstrap_geomean_ratio(on_r, off_r, hib)
            cell = f"{A.geomean(rs.values()):.3f} [{lo:.3f}, {hi:.3f}]"
            # stable_tests takes the app's whole per-configuration map: the noise estimate is pooled across
            # configurations, not read off one arm of the pair.
            stable = A.stable_tests(d, tests)
            scell = "—"
            if stable and len(stable) < len(tests):
                rss = {t: v for t, v in rs.items() if t in stable}
                slo, shi = A.bootstrap_geomean_ratio(on_r, off_r, hib, only=stable)
                scell = f"{A.geomean(rss.values()):.3f} [{slo:.3f}, {shi:.3f}]"
            son = statics.get((app, cfg), {}).get("memory_access_sites", "—")
            sof = statics.get((app, off), {}).get("memory_access_sites", "—")
            out.append(f"| {app} | {A.label(cfg)} | {d[cfg]['n']} / {d[off]['n']} | {cell} | {scell} | {son} / {sof} |")
    if len(out) <= 4:
        out.append("| — | (no completed pair yet) | | | | |")
    p = os.path.join(root, "yield_pairs.md")
    open(p, "w").write("\n".join(out) + "\n")
    print("\n".join(out)); print(f"\n-> {p}")

main()
