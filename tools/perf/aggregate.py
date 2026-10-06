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
        # 2 Oct: one iteration (NTESTS=1) makes memtier print a single "ALL STATS" table instead of BEST/WORST/AGGREGATED;
        # "ALL STATS" never appears in multi-iteration output, so this reads the one-iteration result and changes nothing else.
        if "AGGREGATED AVERAGE RESULTS" in line or line.startswith("ALL STATS"): sec = True
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
    # Non-finite values are dropped rather than propagated: st.stdev over a list of NaN raises
    # AttributeError ('float' object has no attribute 'numerator'), which reads as a bug in the
    # aggregator rather than as missing data and killed the whole table for one dead application.
    xs = [x for x in xs if isinstance(x, (int, float)) and math.isfinite(x)]
    if not xs: return (float("nan"), float("nan"))
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
def estimable_cv(per_cfg, t):
    """pooled_cv, kept separate so callers cannot collapse None into 0.0 by accident."""
    return pooled_cv(per_cfg, t)
def stable_tests(per_cfg, tests, max_cv=0.05):
    """The subtests a run-to-run comparison can actually resolve. The set is derived from the pooled noise of
    each subtest, so it is a property of the workload rather than of any configuration, and it is then applied
    to every configuration alike. Returns None when fewer than half the subtests survive: at that point the
    restricted mean is not a cleaner estimate of the same quantity, it is a different quantity.

    That threshold does not fire anywhere in the f3deebfbab60 campaign, and the figure once quoted here —
    "MySQL, three of five sysbench scripts" — was measured on an earlier compiler and had rotted. Measured
    on this one: MySQL keeps 4 of 5 (only oltp_read_only goes, at 6.10 % pooled CV, against 1.82-3.79 % for
    the rest), SQLite keeps 5 of 7, Redis 16 of 19, memcached has a single metric. A figure carried in a
    code comment rots exactly as one in a document does, so this one names its population."""
    # `(pooled_cv(...) or 0) <= max_cv` TREATED "NOT ESTIMABLE" AS "PERFECTLY STABLE". pooled_cv returns
    # None below three runs per configuration, so at the default N = 2 every subtest scored 0 % and the row
    # read "all N subtests within 5%" — the unmeasured case rendered as the best case, which is the third
    # reason this function can return None and the one the docstring above did not know about. A subtest
    # whose noise cannot be estimated is not known to be stable; it is not known at all.
    keep = [t for t in tests if estimable_cv(per_cfg, t) is not None and estimable_cv(per_cfg, t) <= max_cv]
    return keep if (len(keep) >= 2 and len(keep) * 2 >= len(tests) and len(keep) < len(tests)) else None

def stable_reason(per_cfg, tests, max_cv=0.05):
    """Why stable_tests returned None -- because the two reasons are OPPOSITE and the table showed both as an
    em dash. Every subtest being clean and so few being clean that restricting would measure something else
    are the best and the worst case for a row, and one mark for both invites reading the worst as the best.
    Returns a short phrase, or None when a restricted column exists."""
    if stable_tests(per_cfg, tests, max_cv) is not None: return None
    cvs = [(t, estimable_cv(per_cfg, t)) for t in tests]
    keep = [t for t, c in cvs if c is not None and c <= max_cv]
    pct = int(round(100 * max_cv))
    # THE THIRD REASON, and it must be said before the others: nothing was measured. pooled_cv needs at
    # least three runs in at least three configurations, so at N = 2 no subtest has an estimate and the
    # honest statement is that the restricted column does not exist here, not that every subtest passed.
    if all(c is None for _, c in cvs):
        return 'pooled CV not estimable at this N (needs 3 runs per configuration) - NOT A STABILITY CLAIM'
    if len(tests) == 1:
        c = cvs[0][1]
        return ('single metric, pooled CV {:.1f}%'.format(100 * c) if c is not None
                else 'single metric, pooled CV not estimable at this N - NOT A STABILITY CLAIM')
    if len(keep) == len(tests):
        return 'all {} subtests within {}%'.format(len(tests), pct)
    if len(keep) < 2 or len(keep) * 2 < len(tests):
        return 'only {} of {} within {}% - TOO FEW TO RESTRICT'.format(len(keep), len(tests), pct)
    return '{} of {} within {}%'.format(len(keep), len(tests), pct)
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
def collect(root, app, run_range=None):
    """run_range=(first, last) keeps only run<k> with first <= k <= last.

    The default is every run. The variant that exists for it is (2, 5): run1 of a leg is the first execution
    of that configuration after the warm-up, and before the warm-up existed it carried a cold-start penalty
    large enough to be visible (docs/confounds.md states the effect). Reporting both is how we say
    whether the warm-up actually removed it, rather than assuming it did — the two tables agreeing IS the
    evidence, and they can only agree if both are computed."""
    parser, hib = PARSERS[app]; adir = os.path.join(root, app)
    per_cfg = {}
    for cfg in sorted(os.listdir(adir)):
        cdir = os.path.join(adir, cfg)
        if not os.path.isdir(cdir): continue
        runs = {}; used = 0; skipped = 0; modes = set()
        for r in sorted(os.listdir(cdir)):
            if not re.fullmatch(r"run\d+", r): continue
            if run_range is not None:
                k = int(r[3:])
                if not (run_range[0] <= k <= run_range[1]): continue
            mp = os.path.join(cdir, r, "meta.json")
            if not os.path.exists(mp): continue
            m = json.load(open(mp))
            if m.get("rc") != 0 or m.get("disturbed"): skipped += 1; continue
            try: vals = parser(os.path.join(cdir, r))
            except Exception as e: print(f"  {app}/{cfg}/{r}: parse error {e}", file=sys.stderr); skipped += 1; continue
            if not vals: skipped += 1; continue
            # A run whose real metrics are all zero or non-finite measured NOTHING, and is not a slow
            # measurement. memtier prints "Totals 0.00 ops/sec" when the server never accepted a
            # connection, and that cell used to reach the table and take the whole table down with it.
            # Underscore metrics are excluded here as everywhere: a latency of 0.00 is not a run.
            real = [v for t, v in vals.items() if not t.startswith("_")]
            if not any(isinstance(v, (int, float)) and math.isfinite(v) and v > 0 for v in real):
                print(f"  {app}/{cfg}/{r}: no throughput in any metric "
                      f"({', '.join(f'{t}={v}' for t, v in vals.items())})", file=sys.stderr)
                skipped += 1; continue
            used += 1; modes.add(m.get("mode"))
            for t, v in vals.items(): runs.setdefault(t, []).append(v)
        if used: per_cfg[cfg] = {"runs": runs, "n": used, "skipped": skipped, "modes": sorted(modes)}
    return per_cfg, hib

def static_counts(root):
    p = os.path.join(root, "static-counts.csv"); out = {}
    if os.path.exists(p):
        for row in csv.DictReader(open(p)): out[(row["app"], row["config"])] = row
    return out

def report_app(root, app, per_cfg, hib, statics, out_rows, suffix="", expect_n=5):
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
    empty_out = list(empty)
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
    # A BOOTSTRAP OVER ONE RUN CANNOT PRODUCE AN INTERVAL. Resampling a single value gives that value back,
    # so a mid-leg table printed "0.991 [0.991, 0.991]" -- zero width, which reads as extreme precision to
    # anyone who does not check the N column, and is how a stale table gets quoted (2026-09-16.).
    # Below the expected N the interval is not narrowed, it is ABSENT, and the row says so where the number
    # is rendered rather than leaving the N column to be noticed.
    # THREE RENDERING STATES, keyed on what the data can support rather than on what was asked for.
    #   N >= 5        interval printed
    #   2 <= N < 5    point estimate only. A bootstrap over two, three or four runs produces an interval,
    #                 and it is not one anybody should read: it is the spread of a handful of resamples of
    #                 a handful of points. The artifact's default is ART_RUNS=2 (a full run is under 24 h,
    #                 this subset about 4 h), so this is the state a reviewer sees, and the label tells
    #                 them what to do with it -- compare the point against our shipped interval.
    #   N == 1        not a measurement at all.
    # expect_n still marks a row that fell short of what the caller asked for, which is a different fact
    # from whether an interval is printable: at ART_RUNS=5 a row of 4 is both short AND intervalless, and
    # the reader should see both.
    INTERVAL_MIN_N = 5
    def fmt(point, lo, hi, n, prec=3):
        short = f", short of N={expect_n}" if n < expect_n else ""
        if n < 2:
            return f"{point:.{prec}f} (N={n} — NOT A MEASUREMENT)"
        if n < INTERVAL_MIN_N:
            return f"{point:.{prec}f} (N={n}, no interval; compare with the shipped interval{short})"
        return f"{point:.{prec}f} [{lo:.{prec}f}, {hi:.{prec}f}]" + (f" ({short.lstrip(', ')})" if short else "")
    lines.append("| config | label | N | SU geomean [95 %] | SU stable [95 %] | SD geomean [95 %] | static sites | modes | per-test SU |")
    lines.append("|---|---|---|---|---|---|---|---|---|")
    for cfg, info in per_cfg.items():
        su = sus = sd = "—"; per = ""
        if base_t and cfg != "tsan":
            rs = {t: ratio(med(cfg, t), med("tsan", t), hib) for t in tests if t in info["runs"] and t in base_t["runs"]}
            lo, hi = bootstrap_geomean_ratio(info["runs"], base_t["runs"], hib)
            su = fmt(geomean(rs.values()), lo, hi, info["n"]); per = ", ".join(f"{t}:{v:.2f}" for t, v in rs.items())
            if noisy:
                rss = {t: v for t, v in rs.items() if t in stable}
                los, his = bootstrap_geomean_ratio(info["runs"], base_t["runs"], hib, only=stable)
                if rss: sus = fmt(geomean(rss.values()), los, his, info["n"])
        if base_o and cfg != "orig":
            rs = {t: 1 / ratio(med(cfg, t), med("orig", t), hib) for t in tests if t in info["runs"] and t in base_o["runs"]}
            lo, hi = bootstrap_geomean_ratio(base_o["runs"], info["runs"], hib)   # orig vs cfg = slowdown
            sd = fmt(geomean(rs.values()), lo, hi, info["n"], prec=2)
        stc = statics.get((app, cfg), {}).get("memory_access_sites", "—")
        if sus == "\u2014" and base_t:
            why = stable_reason(per_cfg, tests)
            if why: sus = "\u2014 ({})".format(why)
        lines.append(f"| {cfg} | {label(cfg)} | {info['n']} | {su} | {sus} | {sd} | {stc} | {','.join(info['modes'])} | {per} |")
        out_rows.append({"app": app, "config": cfg, "label": label(cfg), "N": info["n"], "SU": su, "SU_stable": sus, "SD": sd, "static_sites": stc, "modes": ",".join(info["modes"])})
    open(os.path.join(root, f"perf_{app}{suffix}.md"), "w").write("\n".join(lines) + "\n")
    json.dump({cfg: {"n": i["n"], "skipped": i["skipped"], "modes": i["modes"], "runs": i["runs"]} for cfg, i in per_cfg.items()},
              open(os.path.join(root, f"perf_{app}{suffix}.json"), "w"), indent=1)
    with open(os.path.join(root, f"perf_{app}{suffix}.csv"), "w", newline="") as fh:
        w = csv.writer(fh); w.writerow(["config", "test", "n", "median", "mean", "sd"])
        for cfg, info in per_cfg.items():
            for t, xs in info["runs"].items():
                m, sd = mean_sd(xs); w.writerow([cfg, t, len(xs), st.median(xs), m, sd])
    print(f"{app}: {len(per_cfg)} configs, {sum(v['n'] for v in per_cfg.values())} runs -> perf_{app}{suffix}.md")

def label(cfg):
    return {"tsan-dom-ea-lo-st-swmr": "AllOpt-peel", "tsan-dom_peeling-ea-lo-st-swmr": "AllOpt+peel",
            "tsan-dom_peeling-ea-lo-st-swmr-wp": "AllOpt+peel (WP summaries)", "tsan-sound-wp": "sound (WP summaries)",
            # -stmt DELIBERATELY HAS NO ENTRY. Adding one is cosmetic -- the comparator keys on the
            # configuration in column 0 and never reads this -- but it rewrites the label column of every
            # shipped table that carries the configuration, which would force a regeneration of the shipped
            # .md and .csv set to keep the tool and the evidence in agreement. That is a large diff on
            # shipped files for a nicer word, and it was proposed the night before a deadline. The new
            # -stmt-wp entry below appears in no shipped table, so it costs nothing. (22 Sep 2026.)
            "tsan-dom_peeling-ea-lo-st-swmr-stmt-wp": "AllOpt+peel+DynSTC (WP summaries)"}.get(cfg, cfg)

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root"); ap.add_argument("--app", action="append")
    ap.add_argument("--runs", metavar="FIRST-LAST",
                    help="keep only these run indices, e.g. 2-5; output goes to perf_<app>.runs<FIRST>-<LAST>.md")
    ap.add_argument("--suffix", help="filename suffix for the tables (default: derived from --runs)")
    ap.add_argument("--expect-n", type=int, default=5,
                    help="runs expected per configuration; rows below it print no interval and are marked "
                         "NOT A MEASUREMENT (default 5)")
    a = ap.parse_args(); root = os.path.abspath(a.root)
    run_range = None; suffix = a.suffix or ""
    if a.runs:
        m = re.fullmatch(r"(\d+)-(\d+)", a.runs) or sys.exit("--runs wants FIRST-LAST, e.g. 2-5")
        run_range = (int(m.group(1)), int(m.group(2)))
        suffix = a.suffix if a.suffix is not None else f".runs{run_range[0]}-{run_range[1]}"
        # A restricted range has fewer runs BY CONSTRUCTION: --runs 2-5 yields N=4 from a complete leg, and
        # judging it against the full expectation would brand every row of that table NOT A MEASUREMENT.
        # The expectation for a range is the size of the range, unless the caller states otherwise.
        if not any(x.startswith("--expect-n") for x in sys.argv):
            a.expect_n = run_range[1] - run_range[0] + 1
    apps = a.app or [d for d in sorted(os.listdir(root)) if d in PARSERS and os.path.isdir(os.path.join(root, d))]
    if not apps:
        # A HEADERS-ONLY SUMMARY IS NOT A SUMMARY. With no --app and no recognised application directory
        # under the root, this wrote a table with a header row and nothing beneath it and exited 0 -- the
        # same "nothing found reads as nothing wrong" shape as everything else this week. Say which root
        # was looked at and which names would have been recognised. (Audit, 2026-09-19.)
        print(f"no application directories under {root}", file=sys.stderr)
        print(f"  recognised names: {', '.join(sorted(PARSERS))}", file=sys.stderr)
        print("  nothing was aggregated; no summary written.", file=sys.stderr)
        sys.exit(2)
    statics = static_counts(root); rows = []; no_data = []
    for app in apps:
        per_cfg, hib = collect(root, app, run_range)
        if per_cfg: report_app(root, app, per_cfg, hib, statics, rows, suffix, a.expect_n)
        else:
            # No usable run at all: an empty tree, or every cell parsed to nothing. Say so in the
            # table and in the exit status, because a summary that simply omits the application is
            # indistinguishable from one where it was never asked for.
            print(f"{app}: NO DATA — no usable run{' in range ' + a.runs if a.runs else ''}", file=sys.stderr)
            rows.append({"app": app, "config": "—", "label": "—", "N": 0, "SU": "**no data**",
                         "SU_stable": "—", "SD": "—", "static_sites": "—", "modes": "—"})
            no_data.append(app)
    with open(os.path.join(root, f"perf_summary{suffix}.md"), "w") as fh:
        fh.write(f"# P5 summary — {os.path.basename(root)}\n\nSU = speedup vs stock TSan, SD = slowdown vs native; geometric mean over the app's tests on per-test medians of N undisturbed runs; [95 % bootstrap interval]. **SU stable** is the same speedup over the subtests whose stock-TSan baseline CV is at most 5 %, the set chosen once from the baseline and applied to every configuration alike; where there is no restricted column the cell says why in brackets, because the two reasons are opposite: all subtests being within the bound is the best case for a row, and too few being within it to restrict is the worst, and one unannotated mark for both invites reading the worst as the best. Read SU as the headline and SU stable as what the data can resolve; the per-app file names the excluded subtests and their baseline CV.\n\n")
        fh.write("| app | config | label | N | SU | SU stable | SD | static sites | modes |\n|---|---|---|---|---|---|---|---|---|\n")
        for r in rows: fh.write(f"| {r['app']} | {r['config']} | {r['label']} | {r['N']} | {r['SU']} | {r.get('SU_stable','—')} | {r['SD']} | {r['static_sites']} | {r['modes']} |\n")
    print(f"summary -> {os.path.join(root, f'perf_summary{suffix}.md')}")
    if no_data:
        print(f"NO DATA for {', '.join(no_data)}: the summary names them but they measured nothing.",
              file=sys.stderr)
        sys.exit(2)
if __name__ == "__main__": main()
