#!/usr/bin/env python3
"""aggregate.py — P5 performance tables from tools/perf results.

Reads <root>/<app>/<cfg>/run<k>/{meta.json, raw artefact}, parses each run with the application's own
parser (imported from the repo where it is importable), and reports per configuration:
  per test: median / mean ± sample σ / CV over the undisturbed runs (N),
  speedup vs stock TSan (SU) and slowdown vs native (SD) computed on medians, per test and as the geometric
  mean over tests (the paper's definition), with a 95 % bootstrap interval over run resamples,
plus the static instrumentation counts (static-counts.csv) and the run mode/cpuset from session.json.
Outputs perf_<app>.{md,csv,json} per app and perf_summary.md in <root>.
"""
import argparse, csv, glob, json, math, os, random, re, statistics as st, sys
import importlib.util
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "nosql", "redis")); sys.path.insert(0, os.path.join(ROOT, "sql", "sqlite"))
sys.path.insert(0, os.path.join(ROOT, "projects", "ffmpeg"))

# sql/sqlite and projects/ffmpeg both contain a "parse_results.py": a plain `import parse_results` picks
# whichever directory comes first on sys.path and silently parses with the wrong application's rules (it made
# every SQLite run fail with "Is a directory"). Load each helper from its own file instead.
_MODCACHE = {}
def load_module(relpath, name):
    if name not in _MODCACHE:
        spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, relpath))
        mod = importlib.util.module_from_spec(spec)
        # register before executing: @dataclass looks the defining module up in sys.modules
        sys.modules[name] = mod
        spec.loader.exec_module(mod)
        _MODCACHE[name] = mod
    return _MODCACHE[name]

# ---------------------------------------------------------------- per-app parsers -> {test: value}
def parse_memcached(d):
    # memtier: section "AGGREGATED AVERAGE RESULTS" then "Totals <ops/sec> <hits> <misses> <avg latency> ..."
    p = os.path.join(d, "memtier.txt"); sec = False; out = {}
    for line in open(p, errors="replace"):
        if "AGGREGATED AVERAGE RESULTS" in line: sec = True
        if sec and line.startswith("Totals"):
            f = line.split(); out["ops_sec"] = float(f[1]); out["_latency_ms"] = float(f[4]); break
    return out
def parse_redis(d):
    R = load_module("nosql/redis/analyze_results_redis.py", "redis_analyze")
    data = R.parse_results(os.path.join(d, "results.txt"))
    cfgs = list(data); return dict(data[cfgs[0]]) if cfgs else {}
def parse_sqlite(d):
    S = load_module("sql/sqlite/parse_results.py", "sqlite_parse_results")
    return dict(S.parse_log_file(os.path.join(d, "threadtest3.log")))
def parse_mysql(d):
    out = {}
    for f in sorted(os.listdir(d)):
        if not f.endswith(".txt") or f in ("memory.txt",): continue
        txt = open(os.path.join(d, f), errors="replace").read()
        m = re.search(r"^\s*total:\s+(\d+)", txt, re.M)          # "queries performed: ... total: N" (the paper's Total)
        if m: out[f[:-4]] = float(m.group(1))
    return out
def parse_ffmpeg(d):
    F = load_module("projects/ffmpeg/ffmpeg_contention_report.py", "ffmpeg_report")
    from pathlib import Path
    recs = F.load_summary_csv(Path(os.path.join(d, "summary.csv")), 0)
    return {r.codec: r.mean_time_s for r in recs}
PARSERS = {"memcached": (parse_memcached, True), "redis": (parse_redis, True), "sqlite": (parse_sqlite, True),
           "mysql": (parse_mysql, True), "ffmpeg": (parse_ffmpeg, False)}   # (parser, higher_is_better)

# ---------------------------------------------------------------- statistics
def geomean(xs):
    xs = [x for x in xs if x and x > 0]
    return math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs else float("nan")
def mean_sd(xs):
    return (st.mean(xs), st.stdev(xs) if len(xs) > 1 else 0.0)
def ratio(num, den, hib):  # speed ratio "cfg vs base": >1 = cfg faster
    return (num / den) if hib else (den / num)
def cv(xs):
    m = st.mean(xs) if xs else 0
    return (st.stdev(xs) / m) if (len(xs) > 1 and m) else 0.0
def pooled_cv(per_cfg, t):
    """A subtest's run-to-run noise, pooled over every configuration instead of read off the baseline's five
    runs. Five values estimate a CV badly: SQLite's stress1 reads 6.4 % from the baseline alone and 16 % over
    the 65 runs of all configurations, so a fixed threshold applied to the baseline figure includes or excludes
    it almost by luck. Pooling is the RMS of the per-configuration CVs, which is the within-group noise the
    ratio actually has to see through, and it does not depend on which configuration happens to be the base."""
    cvs = [cv(i["runs"][t]) for i in per_cfg.values() if len(i["runs"].get(t, [])) >= 3]
    if len(cvs) < 3: return None
    return math.sqrt(sum(c * c for c in cvs) / len(cvs))
def stable_tests(per_cfg, tests, max_cv=0.05):
    """The subtests a run-to-run comparison can actually resolve. The set is derived from the pooled noise of
    each subtest, so it is a property of the workload rather than of any configuration, and it is then applied
    to every configuration alike. Returns None when fewer than half the subtests survive: at that point the
    restricted mean is not a cleaner estimate of the same quantity, it is a different quantity. MySQL is the
    case in point, where three of five sysbench scripts would go and the surviving pair moves the centre
    without narrowing the interval."""
    keep = [t for t in tests if (pooled_cv(per_cfg, t) or 0) <= max_cv]
    return keep if (len(keep) >= 2 and len(keep) * 2 >= len(tests) and len(keep) < len(tests)) else None
def bootstrap_geomean_ratio(cfg_runs, base_runs, hib, B=2000, seed=1, only=None):
    """cfg_runs/base_runs: {test: [values over runs]}. Resample runs per test independently."""
    rnd = random.Random(seed); tests = [t for t in cfg_runs if t in base_runs and not t.startswith("_")]
    if only is not None: tests = [t for t in tests if t in only]
    if not tests: return (float("nan"), float("nan"))
    vals = []
    for _ in range(B):
        rs = []
        for t in tests:
            c = rnd.choice(cfg_runs[t]); b = rnd.choice(base_runs[t]); rs.append(ratio(c, b, hib))
        vals.append(geomean(rs))
    vals.sort(); return (vals[int(0.025 * B)], vals[int(0.975 * B) - 1])

# ---------------------------------------------------------------- collect
def collect(root, app):
    parser, hib = PARSERS[app]; adir = os.path.join(root, app)
    per_cfg = {}
    for cfg in sorted(os.listdir(adir)):
        cdir = os.path.join(adir, cfg)
        if not os.path.isdir(cdir): continue
        runs = {}; used = 0; skipped = 0; modes = set()
        for r in sorted(os.listdir(cdir)):
            if not re.fullmatch(r"run\d+", r): continue
            mp = os.path.join(cdir, r, "meta.json")
            if not os.path.exists(mp): continue
            m = json.load(open(mp))
            if m.get("rc") != 0 or m.get("disturbed"): skipped += 1; continue
            try: vals = parser(os.path.join(cdir, r))
            except Exception as e: print(f"  {app}/{cfg}/{r}: parse error {e}", file=sys.stderr); skipped += 1; continue
            if not vals: skipped += 1; continue
            used += 1; modes.add(m.get("mode"))
            for t, v in vals.items(): runs.setdefault(t, []).append(v)
        if used: per_cfg[cfg] = {"runs": runs, "n": used, "skipped": skipped, "modes": sorted(modes)}
    return per_cfg, hib

def static_counts(root):
    p = os.path.join(root, "static-counts.csv"); out = {}
    if os.path.exists(p):
        for row in csv.DictReader(open(p)): out[(row["app"], row["config"])] = row
    return out

def report_app(root, app, per_cfg, hib, statics, out_rows):
    lines = [f"# {app}: performance ({'higher' if hib else 'lower'} is better per test)\n"]
    # Configurations that were attempted and produced no usable run must be named: a table generated only from
    # what worked cannot be distinguished from one where nothing else was tried (2026-09-08, SQLite -wp).
    attempted = sorted(d for d in os.listdir(os.path.join(root, app))
                       if os.path.isdir(os.path.join(root, app, d))) if os.path.isdir(os.path.join(root, app)) else []
    empty = []
    for c in attempted:
        if c in per_cfg and per_cfg[c].get("runs"): continue
        why = ""
        for mj in sorted(glob.glob(os.path.join(root, app, c, "run*", "meta.json"))):
            try: m = json.load(open(mj))
            except Exception: continue
            if m.get("error"): why = str(m["error"]).strip().split("\n")[-1][:120]; break
            if m.get("rc"): why = f"rc={m['rc']}"
        empty.append((c, why or "no clean run"))
    if empty:
        # A leg still running looks the same as a failed one here, so say when the snapshot was taken.
        lines.append(f"**Attempted but not measured** (as of {__import__('datetime').datetime.now():%Y-%m-%d %H:%M}, "
                     "so a leg still in progress will list its unfinished configurations)**:** " + "; ".join(f"`{c}` ({w})" for c, w in empty) + "\n")
    # The milder form of the same failure: a configuration that quietly ran fewer repetitions than its peers.
    # The N column shows it, but only if the reader compares rows; say it in words.
    if per_cfg:
        nmax = max(i["n"] for i in per_cfg.values())
        short = [(c, i["n"], i.get("skipped", 0)) for c, i in per_cfg.items() if i["n"] < nmax]
        if short:
            lines.append("**Fewer repetitions than the leg's N=%d:** " % nmax
                         + "; ".join(f"`{c}` N={n}" + (f", {s} discarded" if s else "") for c, n, s in short) + "\n")
    sess = os.path.join(root, app, "session.json"); s = json.load(open(sess)) if os.path.exists(sess) else {}
    lines.append(f"Session: mode={s.get('mode')} cpuset={s.get('cpuset')} governor={s.get('governor')} no_turbo={s.get('no_turbo')} host={s.get('host')} started={s.get('started')}\n")
    base_t = per_cfg.get("tsan"); base_o = per_cfg.get("orig")
    med = lambda c, t: st.median(per_cfg[c]["runs"][t])
    tests = [t for t in (base_t["runs"] if base_t else next(iter(per_cfg.values()))["runs"]) if not t.startswith("_")]
    lines.append("| config | N | " + " | ".join(f"{t} median (mean ± σ, CV)" for t in tests) + " |")
    lines.append("|---|---|" + "---|" * len(tests))
    for cfg, info in per_cfg.items():
        cells = []
        for t in tests:
            xs = info["runs"].get(t, [])
            if not xs: cells.append("—"); continue
            m, sd = mean_sd(xs); cells.append(f"{st.median(xs):.4g} ({m:.4g} ± {sd:.2g}, {100*sd/m if m else 0:.1f} %)")
        lines.append(f"| {cfg} | {info['n']} | " + " | ".join(cells) + " |")
    stable = stable_tests(per_cfg, tests) if base_t else None
    noisy = [t for t in tests if t not in stable] if stable else []
    lines.append("\n## Speedup vs stock TSan (SU) and slowdown vs native (SD), on medians; geometric mean over tests; 95 % bootstrap interval\n")
    if noisy:
        lines.append(f"**SU stable** repeats the speedup over the {len(stable)} of {len(tests)} subtests whose pooled "
                     "run-to-run CV, taken over every configuration rather than off the baseline alone, is at most 5 %. "
                     "The set is a property of the workload, not of a configuration, and applies to every row alike. "
                     "Excluded here: "
                     + "; ".join(f"`{t}` (pooled CV {100*(pooled_cv(per_cfg, t) or 0):.1f} %)" for t in noisy)
                     + ". Report the all-subtest column as the headline and this one as what the data can resolve.\n")
    lines.append("| config | label | N | SU geomean [95 %] | SU stable [95 %] | SD geomean [95 %] | static sites | modes | per-test SU |")
    lines.append("|---|---|---|---|---|---|---|---|---|")
    for cfg, info in per_cfg.items():
        su = sus = sd = "—"; per = ""
        if base_t and cfg != "tsan":
            rs = {t: ratio(med(cfg, t), med("tsan", t), hib) for t in tests if t in info["runs"] and t in base_t["runs"]}
            lo, hi = bootstrap_geomean_ratio(info["runs"], base_t["runs"], hib)
            su = f"{geomean(rs.values()):.3f} [{lo:.3f}, {hi:.3f}]"; per = ", ".join(f"{t}:{v:.2f}" for t, v in rs.items())
            if noisy:
                rss = {t: v for t, v in rs.items() if t in stable}
                los, his = bootstrap_geomean_ratio(info["runs"], base_t["runs"], hib, only=stable)
                if rss: sus = f"{geomean(rss.values()):.3f} [{los:.3f}, {his:.3f}]"
        if base_o and cfg != "orig":
            rs = {t: 1 / ratio(med(cfg, t), med("orig", t), hib) for t in tests if t in info["runs"] and t in base_o["runs"]}
            lo, hi = bootstrap_geomean_ratio(base_o["runs"], info["runs"], hib)   # orig vs cfg = slowdown
            sd = f"{geomean(rs.values()):.2f} [{lo:.2f}, {hi:.2f}]"
        stc = statics.get((app, cfg), {}).get("memory_access_sites", "—")
        lines.append(f"| {cfg} | {label(cfg)} | {info['n']} | {su} | {sus} | {sd} | {stc} | {','.join(info['modes'])} | {per} |")
        out_rows.append({"app": app, "config": cfg, "label": label(cfg), "N": info["n"], "SU": su, "SU_stable": sus, "SD": sd, "static_sites": stc, "modes": ",".join(info["modes"])})
    open(os.path.join(root, f"perf_{app}.md"), "w").write("\n".join(lines) + "\n")
    json.dump({cfg: {"n": i["n"], "skipped": i["skipped"], "modes": i["modes"], "runs": i["runs"]} for cfg, i in per_cfg.items()},
              open(os.path.join(root, f"perf_{app}.json"), "w"), indent=1)
    with open(os.path.join(root, f"perf_{app}.csv"), "w", newline="") as fh:
        w = csv.writer(fh); w.writerow(["config", "test", "n", "median", "mean", "sd"])
        for cfg, info in per_cfg.items():
            for t, xs in info["runs"].items():
                m, sd = mean_sd(xs); w.writerow([cfg, t, len(xs), st.median(xs), m, sd])
    print(f"{app}: {len(per_cfg)} configs -> perf_{app}.md")

def label(cfg):
    return {"tsan-dom-ea-lo-st-swmr": "AllOpt-peel", "tsan-dom_peeling-ea-lo-st-swmr": "AllOpt+peel",
            "tsan-dom_peeling-ea-lo-st-swmr-wp": "AllOpt+peel (WP summaries)", "tsan-sound-wp": "sound (WP summaries)"}.get(cfg, cfg)

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root"); ap.add_argument("--app", action="append")
    a = ap.parse_args(); root = os.path.abspath(a.root)
    apps = a.app or [d for d in sorted(os.listdir(root)) if d in PARSERS and os.path.isdir(os.path.join(root, d))]
    statics = static_counts(root); rows = []
    for app in apps:
        per_cfg, hib = collect(root, app)
        if per_cfg: report_app(root, app, per_cfg, hib, statics, rows)
        else: print(f"{app}: no runs", file=sys.stderr)
    with open(os.path.join(root, "perf_summary.md"), "w") as fh:
        fh.write(f"# P5 summary — {os.path.basename(root)}\n\nSU = speedup vs stock TSan, SD = slowdown vs native; geometric mean over the app's tests on per-test medians of N undisturbed runs; [95 % bootstrap interval]. **SU stable** is the same speedup over the subtests whose stock-TSan baseline CV is at most 5 %, the set chosen once from the baseline and applied to every configuration alike; it is empty where every subtest is inside that bound. Read SU as the headline and SU stable as what the data can resolve; the per-app file names the excluded subtests and their baseline CV.\n\n")
        fh.write("| app | config | label | N | SU | SU stable | SD | static sites | modes |\n|---|---|---|---|---|---|---|---|---|\n")
        for r in rows: fh.write(f"| {r['app']} | {r['config']} | {r['label']} | {r['N']} | {r['SU']} | {r.get('SU_stable','—')} | {r['SD']} | {r['static_sites']} | {r['modes']} |\n")
    print(f"summary -> {os.path.join(root, 'perf_summary.md')}")
if __name__ == "__main__": main()
