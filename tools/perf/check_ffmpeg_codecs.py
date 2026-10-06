#!/usr/bin/env python3
"""check_ffmpeg_codecs.py <results-root> — every FFmpeg run must carry all four codecs.

WHY THIS EXISTS. `-threads` goes straight to the encoder, and libx265 refuses anything above
X265_MAX_FRAME_THREADS (16): at a pinned-CPU-count default of 48 the h265 codec FAILS ON EVERY BUILD and
simply vanishes from the results. Nothing errors. The run parses, the table is produced, and the geomean is
taken over three codecs instead of four -- a different quantity, reported under the same name.

That is why the leg sets FF_THREADS=4. This checks the outcome rather than the setting, because a flag that
reached the script is not the same as a codec that produced a number, and the campaign has already been
bitten once by exactly that gap (a flag recorded in build_info.txt that had not reached the compiler).

A missing codec is not a smaller sample. It changes the SET OF TESTS the geomean covers, so an FFmpeg row
computed over three codecs cannot be compared with one computed over four -- including with the paper's.

TWO MODES, AND THE DIFFERENCE IS DELIBERATE -- read this before reporting the tree-wide mode as broken.

  --run <dir>   one cell. Reads summary.csv and NEVER consults meta.json, so it answers "did all four
                codecs produce a number" for a cell that is disturbed, failed, or otherwise excluded from
                the tables. Called from bench_one.sh while the run is still the thing being decided.
  <root>        the whole tree, as an after-the-fact audit. SKIPS cells with rc != 0 or disturbed, because
                its question is about the rows that will be REPORTED, and a retired cell is not one.

So on a leg the disturbance gate has retired, the tree-wide mode legitimately checks nothing and returns 3
(SKIP, not a pass) while --run still answers for every cell. That is not a contradiction: one asks about the
table, the other about the workload. The evening of 2026-09-17 is the case in point -- a foreign build
retired 14 of 15 cells, and the per-run mode still established that the 1 GB /dev/shm fix had restored
copy_passthrough and mjpeg, which is a fact about the harness and not about the machine's load.
"""
import json, glob, os, sys
from collections import defaultdict

EXPECTED = {"copy_passthrough", "h264_libx264", "h265_libx265", "mjpeg"}

def load_parser():
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "agg", os.path.join(os.path.dirname(os.path.abspath(__file__)), "aggregate.py"))
    agg = importlib.util.module_from_spec(spec); sys.modules["agg"] = agg; spec.loader.exec_module(agg)
    return agg.PARSERS["ffmpeg"][0]


def check_one(rd):
    """One run directory: 0 if it carries all four codecs, 2 with a reason if it does not.

    The per-cell entry point, called from bench_one.sh while the run is still the thing being decided,
    so that a cell missing a codec FAILS instead of entering the table as a smaller sample. The tree-wide
    mode below stays as the after-the-fact audit; both read EXPECTED from here, so there is one list."""
    try:
        got = {k for k in load_parser()(rd) if not k.startswith("_")}
    except Exception as e:
        print(f"codec check: run output unparseable: {type(e).__name__}: {e}")
        return 2
    missing = EXPECTED - got
    if missing:
        print("missing codec(s): " + ", ".join(sorted(missing)) + "; got " + (", ".join(sorted(got)) or "none")
              + ". A run with fewer codecs is a different test set, not a smaller sample."
              + " Causes seen: /dev/shm too small for the output (copy_passthrough and mjpeg write the"
              + " largest files; Docker's default is 64 MB), and FF_THREADS above 16 (libx265 refuses"
              + " more than 16 frame threads and drops out silently).")
        return 2
    return 0


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--run":
        return check_one(sys.argv[2])
    root = sys.argv[1] if len(sys.argv) > 1 else "results/campaign-f3deebfbab60/primary"
    import importlib.util
    spec = importlib.util.spec_from_file_location("agg", os.path.join(os.path.dirname(os.path.abspath(__file__)), "aggregate.py"))
    agg = importlib.util.module_from_spec(spec); sys.modules["agg"] = agg; spec.loader.exec_module(agg)
    parser, _ = agg.PARSERS["ffmpeg"]
    d = os.path.join(root, "ffmpeg")
    if not os.path.isdir(d):
        print(f"no ffmpeg runs under {root}"); return 1
    bad = []; seen = defaultdict(set); n = 0
    for m in sorted(glob.glob(f"{d}/*/run*/meta.json")):
        rd = os.path.dirname(m); b = os.path.basename(rd)
        if not b[3:].isdigit(): continue                      # run1.disturbed.*, warmup*
        j = json.load(open(m))
        if j.get("rc") != 0 or j.get("disturbed"): continue
        n += 1
        try: got = {k for k in parser(rd) if not k.startswith("_")}
        except Exception as e: bad.append((j["config"], b, f"parse error: {e}")); continue
        seen[j["config"]] |= got
        missing = EXPECTED - got
        if missing: bad.append((j["config"], b, "missing " + ", ".join(sorted(missing))))
    print(f"ffmpeg runs checked: {n}")
    if not n:
        # SKIP, not PASS (a distinction drawn 2026-09-16). "No runs exist yet" and "every run carries
        # all four codecs" are opposite states, and returning 0 for both means an automated caller treats an
        # unmeasured leg as a verified one -- the same shape as the leg that reported complete having run
        # nothing. Exit 3 so a caller can tell absence of evidence from evidence.
        print("  SKIP: no ffmpeg runs in this tree — nothing was checked, and that is not a pass")
        return 3
    if bad:
        print(f"  RUNS WITH A MISSING CODEC: {len(bad)}  <<< the geomean would cover a different test set")
        for cfg, run, why in bad[:20]: print(f"    {cfg:38s} {run:8s} {why}")
        print("  Check FF_THREADS: libx265 refuses more than 16 frame threads and drops out silently.")
        return 2
    print(f"  all {n} runs carry all four codecs: {', '.join(sorted(EXPECTED))}")
    odd = {c: v for c, v in seen.items() if v != EXPECTED}
    if odd:
        print("  configurations whose codec set differs from the expected four:")
        for c, v in odd.items(): print(f"    {c}: {sorted(v)}")
        return 2
    return 0

sys.exit(main())
