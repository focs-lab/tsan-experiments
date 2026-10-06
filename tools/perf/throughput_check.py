#!/usr/bin/env python3
"""Did this run's workload actually produce throughput?

Exit 0 when at least one real metric is finite and positive; exit 1 with a one-line reason otherwise.

The parsers are aggregate.py's own, imported rather than reimplemented, so this gate and the table it
guards cannot disagree about what a run produced. Metrics whose name starts with '_' are excluded here
as they are there: memcached's `_latency_ms` reads 0.00 on a run that never connected, and a latency is
not evidence of throughput.

This checks that the workload produced SOMETHING, not that it produced everything: an FFmpeg run that
lost two of its four codecs passes here and is caught by check_ffmpeg_codecs.py, which is the gate for
completeness. Keeping them apart keeps each one's failure legible.
"""
import importlib.util, math, os, sys


def main():
    if len(sys.argv) != 3:
        print("usage: throughput_check.py <app> <run-dir>", file=sys.stderr)
        return 2
    app, d = sys.argv[1], sys.argv[2]
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("p5_aggregate", os.path.join(here, "aggregate.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    entry = mod.PARSERS.get(app)
    if entry is None:
        # Not a pass: an application the aggregator cannot read is one whose cells cannot be checked,
        # and silence here would be indistinguishable from a clean run.
        print(f"no parser for {app}: throughput cannot be checked")
        return 1
    try:
        vals = entry[0](d)
    except Exception as e:
        print(f"workload output unparseable: {type(e).__name__}: {e}")
        return 1
    if not vals:
        print("workload produced no metrics at all")
        return 1
    real = {t: v for t, v in vals.items() if not t.startswith("_")}
    if any(isinstance(v, (int, float)) and math.isfinite(v) and v > 0 for v in real.values()):
        return 0
    print("no throughput in any metric: " + ", ".join(f"{t}={v}" for t, v in sorted(vals.items())))
    return 1


if __name__ == "__main__":
    sys.exit(main())
