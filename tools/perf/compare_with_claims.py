#!/usr/bin/env python3
"""compare_with_claims.py — did your run reproduce ours?

    compare_with_claims.py PERFORMANCE.md results/perf-redis-20260918-120000 [more trees...]

For every configuration row the artifact claims, prints your value, our shipped interval, and a verdict.
Exit codes, because three outcomes were being spelled as two:
  0   every judged row is inside its interval and every tree could be compared.
  1   a judged row is outside, or a tree could not be read at all (no table, no shipped data, unknown app).
  2   the run is VALID but nothing in it could be compared with ours, for a reason that is a property of
      the machine: a different processor-set shape, thread count or input clip. Not a failure to reproduce
      -- a measurement that was never in a position to test the claim. evaluate.sh reports it apart.
  64  usage error (EX_USAGE, as bench_one.sh already uses 65 and 66 for its cell gates). This was 2 until
      22 Sep 2026; sharing a code with the verdict above would have let a comparator called with no trees
      at all -- an empty glob, an unset array -- report "not applicable on this machine" and read as a pass.

WHAT IS AND IS NOT JUDGED, because a verdict on a row that cannot be compared is worse than no verdict:

  not judged      the stock-against-native ratio. Byte-identical binaries on this host differed by 14%
                  in throughput six days apart (docs/confounds.md), which is wider than the interval we
                  print for it, so an evaluator lands outside it routinely and it means nothing.
  not comparable  the run's workload differs from the campaign's -- a thread count other than ours, or
                  an FFmpeg clip that is not the reference one. A row that agrees at the wrong thread
                  count is worse than one that disagrees, because it looks like agreement.
  no verdict      fewer than two runs. N=1 is not a measurement and the artifact says so elsewhere.

THE EXPECTED THREAD COUNT IS READ FROM OUR SHIPPED DATA, never hardcoded here: a constant in this file
would rot the moment the campaign's parameters changed, and the shipped meta.json is the record.
"""
import glob, json, math, os, re, sys

def flag_labels():
    """The labels of the UPSTREAM-FLAG configurations, derived from the configuration names.

    The flag table in CLAIMS carries context rows too (stock, the sound bundle) so that the flag's effect
    can be read against something; those are not flag configurations and must not be reported as
    "measured, not claimed". Deriving the set from names ending in -nofe keeps that distinction with the
    configurations rather than with the prose of a label."""
    return {v for k, v in LABEL.items() if k.endswith("-nofe")}

def _heading_threads(line):
    """The thread count a section heading states, or None. Two exact forms only, plus memcached's.

    The count is a property of the ROW, not of the application: it is the condition the interval was
    measured under, so it belongs beside the interval. shape.json is per-application and cannot express
    "these rows at 16, those at 4", which is what FFmpeg needs from 2026-09-22. Parsing prose is the weak
    point, so this is strict rather than clever: an ambiguous heading is treated as unannotated and its
    rows behave exactly as before. (design settled 2026-09-21.)"""
    for pat in (r"-threads (\d+)", r"server at (\d+) threads", r"(\d+) threads"):
        m = re.search(pat, line)
        if m:
            return m.group(1)
    return None

def claims_rows(path):
    """{app: {threads_key: {row: (point, lo, hi)}}} from PERFORMANCE.md's own tables.

    threads_key is the count the section heading states, or None where it states none (Redis, SQLite).
    The upstream-flag table is stored under the extra key "flag": {threads_key: {configuration: iv}},
    bucketed by its own Application column rather than by a heading, because one table carries rows for
    several applications."""
    out, app, cols, tkey, flag = {}, None, None, None, False
    for line in open(path, encoding="utf-8"):
        if line.startswith("### "):
            cols = None
            tkey = _heading_threads(line)
            m = re.match(r"^### (\w+)", line)
            app = m.group(1).lower() if m else None
            # The flag section is not an application section: its rows name their own applications.
            flag = "instrument-func-entry-exit" in line
            if app and not flag:
                out.setdefault(app, {}).setdefault(tkey, {})
        if app is None and not flag:
            continue
        if not flag:
            m = re.search(r"Stock ThreadSanitizer against native:\s*([\d.]+)x?\s*\[([\d.]+),\s*([\d.]+)\]", line)
            if m:
                out[app][tkey]["stock vs native"] = tuple(float(x) for x in m.groups())
        if line.startswith("| Configuration |") or line.startswith("| Application |"):
            cols = [c.strip() for c in line.strip().strip("|").split("|")]; continue
        if not cols or not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) != len(cols) or "All five runs [95%]" not in cols:
            continue
        m = re.search(r"([\d.]+)\s*\[([\d.]+),\s*([\d.]+)\]", cells[cols.index("All five runs [95%]")])
        if not m:
            continue
        iv = tuple(float(x) for x in m.groups())
        if "Application" in cols:
            acell = cells[cols.index("Application")]
            a = acell.split()[0].lower() if acell.split() else None
            if not a:
                continue
            t = re.search(r"\((\d+) threads\)", acell)
            out.setdefault(a, {}).setdefault("flag", {}).setdefault(t.group(1) if t else None, {})[
                cells[cols.index("Configuration")]] = iv
        else:
            out.setdefault(app, {}).setdefault(tkey, {})[cells[0]] = iv
    return out

# A CONFIGURATION MISSING FROM HERE USED TO VANISH. LABEL is a plain dict and the row loop iterated
# CLAIMS's rows, so a run configuration with no entry was silently absent from the table -- the
# absence-as-silence shape. The loop now iterates the RUN's configurations and says so when one is not in
# CLAIMS, so a future `-nofe`-style addition announces itself. (2026-09-22.)
LABEL = {"tsan-sound": "four sound analyses",
         "tsan-nofe": "stock with the flag",
         "tsan-sound-nofe": "four sound analyses with the flag",
         "tsan-dom_peeling-ea-lo-st-swmr-nofe": "AllOpt with peeling and the flag",
         "tsan-dom_peeling-ea-lo-st-swmr-stmt-nofe": "AllOpt with peeling, DynSTC and the flag",
         "tsan-dom_peeling-ea-lo-st-swmr": "AllOpt with peeling", "tsan-stmt": "DynSTC",
         "tsan-dom-ea-lo-st-swmr": "AllOpt without peeling", "tsan-ea": "EA", "tsan-lo": "LO",
         "tsan-st": "STC", "tsan-swmr": "SWMR", "tsan-dom": "DE", "tsan-dom_peeling": "DE + peeling",
         # The three rows that were silently never judged until 19 Sep 2026 (no label, so `continue`).
         "tsan-dom_peeling-ea-lo-st-swmr-stmt": "AllOpt with peeling and DynSTC",
         "tsan-dom_peeling-ea-lo-st-swmr-wp": "AllOpt with peeling, whole-program summaries",
         "tsan-dom_peeling-ea-lo-st-swmr-stmt-wp": "AllOpt with peeling, DynSTC and whole-program summaries",
         "tsan-sound-wp": "four sound analyses, whole-program summaries"}

def expected_threads(root, app):
    """Our campaign's thread count for this application, from the shipped data. None if not shipped."""
    for m in sorted(glob.glob(os.path.join(root, "data", "perf", "campaign-*", "primary", app, "*", "run*", "meta.json"))):
        try:
            v = json.load(open(m)).get("threads_setting")
        except Exception:
            continue
        if v not in (None, ""):
            return str(v)
    return None

def reference_input_sha(root, app):
    """The input hash our shipped campaign cells record for this application, from the data, never a constant."""
    for m in sorted(glob.glob(os.path.join(root, "data", "perf", "campaign-*", "primary", app, "*", "run*", "meta.json"))):
        try:
            v = json.load(open(m)).get("input_sha256")
        except Exception:
            continue
        if v:
            return v
    return None

def expected_shape(root):
    """Our campaign's processor-set SHAPE, from the shipped data. None if not shipped.

    Read from data/perf/campaign-*/shape.json rather than derived: the shape of a cpuset depends on the
    topology of the machine it ran on, so an evaluator computing the sibling structure of "4-27,60-83"
    would get THEIR machine's answer and not ours. Cells recorded from 2026-09-20 carry the two numbers
    themselves; the campaign's predate that, which is why the file exists."""
    for f in sorted(glob.glob(os.path.join(root, "data", "perf", "campaign-*", "shape.json"))):
        try:
            j = json.load(open(f))
            if j.get("n_physical_cores"):
                return j["n_physical_cores"], j.get("smt_pairs_complete"), j.get("cpuset")
        except Exception:
            continue
    return None

def run_cpuset(tree, app):
    for m in sorted(glob.glob(os.path.join(tree, app, "*", "run*", "meta.json"))):
        try:
            c = json.load(open(m)).get("cpuset")
        except Exception:
            continue
        if c: return c
    return None

def run_shape(tree, app):
    """The run's own shape, from its cells. None when the run predates the recording."""
    for m in sorted(glob.glob(os.path.join(tree, app, "*", "run*", "meta.json"))):
        try:
            j = json.load(open(m))
        except Exception:
            continue
        if j.get("n_physical_cores"):
            return j["n_physical_cores"], j.get("smt_pairs_complete")
    return None

def run_facts(tree, app, ref_sha=None):
    """N, the effective thread count, and whether FFmpeg ran on the reference clip: the recorded flag, or,
    where a run predates the flag (our own campaign's FFmpeg cells), its recorded input hash equal to the
    hash the shipped campaign records."""
    n, threads, isref = 0, None, None
    for m in sorted(glob.glob(os.path.join(tree, app, "*", "run*", "meta.json"))):
        try:
            j = json.load(open(m))
        except Exception:
            continue
        if j.get("rc") != 0 or j.get("disturbed"):
            continue
        n += 1
        if threads is None and j.get("threads_setting") not in (None, ""):
            threads = str(j["threads_setting"])
        if isref is None and j.get("input_is_reference") is not None:
            isref = bool(j["input_is_reference"])
        elif isref is None and ref_sha and j.get("input_sha256"):
            isref = (j["input_sha256"] == ref_sha)
    per_cfg = len({os.path.basename(os.path.dirname(os.path.dirname(m)))
                   for m in glob.glob(os.path.join(tree, app, "*", "run*", "meta.json"))}) or 1
    return max(1, n // per_cfg), threads, isref

def parse_table(tree, app):
    """{row_label: (point, interval or None, N of that row or None)} from the SUMMARY table of the run's own
    perf_<app>.md. The per-test table above it has the same shape and was parsed too until 22 Sep 2026.

    Both tables begin `| config |` and both can have nine cells -- SQLite's per-test table has seven
    subtests -- so a cell count cannot tell them apart. Reading the per-test table took column 3 to be a
    ratio when it was the second subtest's throughput: `tsan` was carried as an unlabelled configuration,
    and every labelled row was read once with a wrong point and then OVERWRITTEN by the summary row,
    which is later in the file. The printed values were right by table order alone. FFmpeg escaped only
    because four subtests make six cells. (found in review)

    N is the row's own (column 3 of the summary): a tree-wide N derived from clean runs over
    configurations read one disturbed cell in one configuration as N = 1 for every row (19 Sep 2026)."""
    p = os.path.join(tree, f"perf_{app}.md")
    if not os.path.exists(p):
        return None
    out = {}
    in_summary = False
    for line in open(p, encoding="utf-8"):
        if line.startswith("| config | label |"):   # the summary's header; the per-test table's is "| config | N |"
            in_summary = True
            continue
        if not in_summary or not line.startswith("| "):
            continue
        c = [x.strip() for x in line.strip().strip("|").split("|")]
        if len(c) < 8:
            continue
        cfg = c[0]
        if cfg == "tsan":
            # The baseline. Every configuration row is a ratio against it, so it has no row of its own;
            # its SU cell is an em dash today, and skipping it by name keeps that true if that changes.
            continue
        m = re.match(r"([\d.]+)(?:\s*\[([\d.]+),\s*([\d.]+)\])?", c[3])
        if not m:
            continue
        pt = float(m.group(1))
        iv = (float(m.group(2)), float(m.group(3))) if m.group(2) else None
        mn = re.match(r"(\d+)$", c[2])
        nrow = int(mn.group(1)) if mn else None
        if cfg == "orig":
            out["stock vs native"] = (pt, iv, nrow)
        elif cfg not in LABEL:
            # AN UNLABELLED CONFIGURATION MUST NOT VANISH. Dropping it here meant a configuration the run
            # measured produced no line at all: not judged, not refused, not mentioned -- while sitting in
            # the run's own table two files away. That is the absence-as-silence shape one level below the
            # one the main loop was fixed for, and it is exactly what a new `-nofe`-style family would hit
            # on the day it is added. Carried through under a marker so the loop can say so. (2026-09-22.)
            out[f"(unlabelled) {cfg}"] = (pt, iv, nrow)
        elif cfg in LABEL:
            out[LABEL[cfg]] = (pt, iv, nrow)
    return out

def main():
    if len(sys.argv) < 3:
        print(__doc__.strip()); return 64
    claims_path, trees = sys.argv[1], sys.argv[2:]
    root = os.path.dirname(os.path.abspath(claims_path))
    claims = claims_rows(claims_path)
    outside = judged = unjudged = 0
    # A row refused because of the MACHINE -- its processor-set shape, its thread count, its input clip --
    # is counted apart from a row refused for any other reason, because the two earn different exit codes.
    # A 16- or 32-processor host on which nothing could be compared has still produced a valid measurement,
    # and telling it "this is not a pass" is the verdict a row OUTSIDE its interval deserves. `stock vs
    # native` is exempt from both counts: session drift is wider than that interval on every machine, ours
    # included, so it is never judged anywhere and its presence must not decide the exit code.
    not_comparable = other_unjudged = 0
    # WHICH FIGURES THESE VERDICTS ARE AGAINST, said before the table rather than left to be inferred.
    # The artifact's intervals are the campaign on the shipped compiler, which is the camera-ready's set of
    # figures; the submitted version's numbers are a separate column in PERFORMANCE.md and are not what a row is
    # judged against. A reader who assumes the wrong one misreads every line below. (2026-09-21.)
    print("Verdicts are against the intervals in PERFORMANCE.md: the campaign on the shipped compiler,")
    print("the camera-ready's figures. The submitted version's figures are in that file's 'Paper' column.")
    print()
    print(f"{'app':10} {'row':24} {'yours':>22}  {'ours (N=5)':22} verdict")
    print("-" * 100)
    for tree in trees:
        app = next((a for a in claims if f"perf-{a}-" in os.path.basename(tree.rstrip("/"))), None)
        if app is None:
            print(f"{os.path.basename(tree):10} {'-':24} {'':>22}  {'':22} cannot tell which application"); unjudged += 1; continue
        rows = parse_table(tree, app)
        if not rows:
            print(f"{app:10} {'-':24} {'':>22}  {'':22} NO TABLE (the leg produced none)"); unjudged += 1; continue
        n, threads, isref = run_facts(tree, app, reference_input_sha(root, app))
        want = expected_threads(root, app)
        # A MISSING THREAD COUNT IS NOT A MATCHING ONE. Runs made before the harness recorded the
        # EFFECTIVE thread count wrote an empty field, and reading that as "comparable" is the same
        # mistake this whole file exists to prevent -- the absence and the pass sharing a channel. If
        # we know what ours was and the run does not say what its was, we decline to judge it.
        # FOUR COMBINATIONS, NOT TWO. `want` being absent means either "this application has no thread
        # knob" (redis and sqlite record nothing, and nothing is the right answer for both sides) or "the
        # shipped campaign data is missing", and those need opposite treatment. Collapsing them was the
        # same absence-as-a-match bug one level up: with no shipped data every row would have been judged
        # with no comparability check at all, silently.
        # SHAPE BEFORE THREADS. A set of the same SIZE but a different shape is a different machine --
        # 48 logical processors are 24 cores with both SMT siblings on our host and can be 48 separate
        # cores elsewhere, twice the compute with no sibling contention -- and comparing across that is
        # meaningless however well the thread counts agree. (2026-09-20.)
        # Graduated, because refusing every run made before the shape was recorded would discard our own
        # rehearsal evidence, which WAS measured on the campaign's set. Strongest basis available wins,
        # and the weaker one says so: a matching cpuset STRING is only evidence of a matching shape on the
        # same host, since the sibling structure of "4-27,60-83" is a property of the machine.
        # THE SHAPE DECISION IS ITS OWN CHAIN, NOT THE HEAD OF THIS ONE. Folding it in as leading `elif`s
        # meant the row-three case -- shape unrecorded, cpuset ours -- SATISFIED the chain and stopped it,
        # so the thread and clip checks below were never reached: FFmpeg rows on a REGENERATED clip were
        # judged IN/OUT although every cell said input_is_reference false. A guard that silently disables
        # the guards after it is worse than the bug it was added for. (found in review)
        ours_shape, mine_shape = expected_shape(root), run_shape(tree, app)
        why = None; basis = None
        if ours_shape and mine_shape and ours_shape[:2] != mine_shape:
            why = (f"not comparable: {mine_shape[0]} physical cores, {mine_shape[1]} full SMT pairs; "
                   f"ours {ours_shape[0]} and {ours_shape[1]}")
        elif ours_shape and not mine_shape:
            mine_cs = run_cpuset(tree, app)
            if mine_cs and ours_shape[2] and mine_cs == ours_shape[2]:
                basis = (f"shape not recorded (cells predate 2026-09-20); matched on cpuset {mine_cs}, "
                         "which is our shape only if this is the same host")
            else:
                why = (f"not judged: no processor-set shape recorded and cpuset {mine_cs or 'unknown'!s} "
                       f"is not ours ({ours_shape[2]})")
        # WHICH BUCKET OF CLAIMS'S ROWS THIS RUN IS JUDGED AGAINST. From 2026-09-22 FFmpeg has rows at
        # two thread counts, so "the application's rows" is no longer a single set: the run's own recorded
        # count chooses. A count CLAIMS has no rows for is REFUSED by name rather than compared against
        # whichever section happened to parse first, which is what a single-bucket tool would have done
        # silently the moment the second section appeared.
        buckets = claims.get(app, {})
        flagrows = buckets.get("flag", {})
        tkeys = sorted(k for k in buckets if k not in (None, "flag"))
        bucket, tkey = {}, None
        if tkeys:
            if threads and threads in buckets:
                bucket, tkey = buckets[threads], threads
            elif threads:
                why = why or (f"not comparable: {threads} threads; PERFORMANCE.md has rows at {', '.join(tkeys)}")
            else:
                why = why or "not judged: this run records no effective thread count"
        else:
            bucket, tkey = buckets.get(None, {}), None
        fbucket = flagrows.get(tkey if tkey in flagrows else (threads if threads in flagrows else None), {})

        # Every remaining condition is still evaluated when the shape did not already refuse the tree.
        if why is not None:
            pass
        elif not tkeys and threads and want and threads != want:
            why = f"not comparable: {threads} threads, ours {want}"
        elif not tkeys and want and not threads:
            why = "not judged: this run records no effective thread count"
        elif not tkeys and threads and not want:
            why = ("not judged: no shipped campaign data to compare the thread count with "
                   f"(looked in {os.path.join(root, 'data', 'perf')})")
        elif app == "ffmpeg" and isref is not True:
            # An absent flag is not the reference clip: the same absence-as-a-match shape as above.
            why = ("not comparable: not the reference clip" if isref is False
                   else "not judged: the run does not record whether its clip is the reference")
        # EVERY TREE MUST PRODUCE A LINE. If CLAIMS's column header or a row label drifts for ONE
        # application while the others parse, this loop simply does not execute for it: nothing is
        # printed, nothing is judged, and the summary still reports success on the other applications.
        # Silence for a tree the caller explicitly named is the same failure as silence overall, and the
        # all-or-nothing guard below does not catch it. (Audit, 2026-09-19.)
        def verdict(pt, iv, ours):
            """The comparison itself, shared by judged rows and flag rows so the two cannot diverge."""
            if iv:
                overlap = iv[0] <= ours[2] and ours[1] <= iv[1]
                agree = (iv[0] <= 1.0 <= iv[1]) == (ours[1] <= 1.0 <= ours[2])
                ins = overlap and agree
                if ins: return "IN (intervals overlap)", True
                if not overlap:
                    return f"OUT: intervals do not overlap (gap {max(iv[0] - ours[2], ours[1] - iv[1]):.3f})", False
                return "OUT: one interval contains 1.0 and the other does not", False
            ins = ours[1] <= pt <= ours[2]
            if ins: return "IN ", True
            return (f"OUT by {ours[1] - pt:.3f} below" if pt < ours[1]
                    else f"OUT by {pt - ours[2]:.3f} above"), False

        # THE LOOP RUNS OVER THE RUN'S ROWS, NOT CLAIMS'S. Iterating CLAIMS meant a configuration the run
        # measured but CLAIMS does not carry was skipped in silence -- so an unlabelled or unclaimed
        # configuration simply did not appear. Every row the run produced now gets a line.
        printed = 0
        for label in sorted(rows):
            pt, iv, nrow = rows[label]
            n_here = nrow or n
            yours = f"{pt:.3f} [{iv[0]:.3f}, {iv[1]:.3f}]" if iv else f"{pt:.3f} (N={n_here})"
            ours = bucket.get(label)
            fiv = fbucket.get(label) if label in flag_labels() else None
            if ours is None and fiv is None:
                # A tree already refused as a whole is not ALSO told its rows are unknown: the reason it
                # was refused is the useful line, and "not in CLAIMS" would suggest a second, different
                # problem. (Spec case: an 8-thread FFmpeg run against rows at 16 and 4.)
                printed += 1 if why else 0
                if label.startswith("(unlabelled) "):
                    # A different cause from "not in CLAIMS": the documents may well carry this row; the
                    # comparator has no name for the configuration, which is a gap in LABEL, not in CLAIMS.
                    reason = (f"no label for configuration {label[13:]!r}; add it to LABEL in "
                              "compare_with_claims.py so this row can be compared")
                else:
                    reason = why or "not in PERFORMANCE.md for this application at this thread count"
                if label != "stock vs native":
                    if why and why.startswith("not comparable") and not label.startswith("(unlabelled) "):
                        not_comparable += 1
                    else:
                        other_unjudged += 1
                print(f"{app:10} {label[:24]:24} {yours:>22}  {'':22} {reason}")
                continue
            printed += 1
            shipped = f"{(ours or fiv)[0]:.3f} [{(ours or fiv)[1]:.3f}, {(ours or fiv)[2]:.3f}]"
            if ours is None:
                # Measured and reported, counted in neither total: the flag is upstream's, so a row about
                # it is evidence in this artifact and not a claim of this paper.
                if why:
                    if why.startswith("not comparable"): not_comparable += 1
                    v = f"measured, not claimed (upstream flag): {why}"
                else:
                    t, ins = verdict(pt, iv, fiv)
                    v = f"measured, not claimed (upstream flag): {'inside' if ins else 'outside'} our interval"
                print(f"{app:10} {label:24} {yours:>22}  {shipped:22} {v}")
                continue
            if label == "stock vs native":
                v = "not judged (session drift is wider than this interval)"
            elif n_here < 2:
                v = "no verdict (N<2 is not a measurement)"; other_unjudged += 1
            elif why:
                v = why
                if why.startswith("not comparable"): not_comparable += 1
                else: other_unjudged += 1
            else:
                judged += 1
                v, inside = verdict(pt, iv, ours)
                if not inside:
                    outside += 1
                if ours[1] > 1.0 or ours[2] < 1.0:
                    same = (pt > 1.0) == (ours[0] > 1.0)
                    v += ", same side of 1.0" if same else ", WRONG SIDE OF 1.0"
                    if not same and inside:
                        outside += 1
            print(f"{app:10} {label:24} {yours:>22}  {shipped:22} {v}")
        if basis and printed:
            print(f"{'':10}   basis: {basis}")
        missing = [r for r in bucket if r not in rows]
        if printed and missing:
            print(f"{app:10} {len(missing)} of {len(bucket)} rows PERFORMANCE.md ships for this application"
                  + (f" at {tkey} threads" if tkey else "")
                  + " were not produced by this run"
                  + (" (the default subset)" if len(rows) <= 4 else "") + "; nothing is judged for them.")
        if not printed:
            cl = sorted(bucket) or ["(none parsed from PERFORMANCE.md)"]
            rn = sorted(rows) or ["(none parsed from the run's table)"]
            print(f"{app:10} {'-':24} {'':>22}  {'':22} TABLES COULD NOT BE MATCHED")
            print(f"{'':10}   PERFORMANCE.md offers: {', '.join(cl)}")
            print(f"{'':10}   the run offers:   {', '.join(rn)}")
            print(f"{'':10}   no row name appears on both sides, so nothing could be compared.")
            unjudged += 1
    print("-" * 100)
    if judged:
        # Two counts, not one: a judged row outside its interval and a tree that could not be compared at
        # all are different failures, and "2 not inside" once counted both (found by the reviewer
        # walkthrough, 19 Sep 2026).
        print(f"{judged} rows judged, {outside} outside their intervals"
              + (f"; {unjudged} tree(s) could not be compared at all (see above)." if unjudged else "."))
    elif not_comparable and not other_unjudged and not unjudged:
        # A THIRD OUTCOME, because two were being spelled as one. Every row refused for a property of this
        # machine is a different event from a row that missed its interval, and both printed "this is not a
        # pass" and returned 1 -- so every unpinned run on a 16- or 32-processor host, which is most
        # reviewers and every student, read as a failed reproduction of a paper whose numbers it had never
        # been in a position to test. The refusal is right and stays; only the verdict on it changes.
        print("NO ROW COMPARABLE ON THIS MACHINE: every row above carries its ratio against stock and the")
        print("reason (a different processor-set shape, thread count or input); the run is a valid")
        print("measurement and its ratios can be read by eye against the intervals, but none is judged.")
        print("The intervals describe 24 physical cores with both SMT threads (48 logical processors); pin")
        print("such a set (ART_CPUSET) to be compared.")
        return 2
    else:
        # NOTHING JUDGED IS NOT A PASS, and this file said so in its own docstring while returning 0 for
        # it: "0 judged, 0 not inside" and "all judged, none outside" shared an exit code, so a run in
        # which every row was not-comparable reported PASS to evaluate.sh. The rule the file exists to
        # enforce, broken by the file. (Found by the audit of 2026-09-19.)
        print("NO ROWS COULD BE JUDGED — this is not a pass. Nothing above was compared with the shipped")
        print("intervals; read the reasons on each line (not comparable, no table, no verdict below N=2,")
        print("no shipped campaign data) and fix the cause before reading any number as reproduction.")
    return 1 if (outside or unjudged or not judged) else 0

if __name__ == "__main__":
    sys.exit(main())
