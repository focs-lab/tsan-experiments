#!/usr/bin/env python3
"""
Build a speedup table from summary_ffmpeg_benchmark.csv.
Speedup = tsan_mean_time / config_mean_time  (>1 means faster than tsan).
Baseline build: "ffmpeg-tsan"
"""

import csv
import sys
from pathlib import Path

BASELINE = "ffmpeg-tsan"
CSV_FILE = Path(__file__).parent / "summary_ffmpeg_benchmark.csv"

if len(sys.argv) > 1:
    CSV_FILE = Path(sys.argv[1])

# ── load data ────────────────────────────────────────────────────────────────
# codec -> build -> mean_time_s
data: dict[str, dict[str, float]] = {}

with open(CSV_FILE, newline="") as f:
    reader = csv.DictReader(f)
    for row in reader:
        codec = row["Codec"].strip('"')
        build = row["FFBUILD"].strip('"')
        mean  = float(row["mean_time_s"])
        data.setdefault(codec, {})[build] = mean

# ── collect ordered codec / build lists ──────────────────────────────────────
codecs = list(data.keys())

# all builds, baseline first, rest in sorted order
all_builds: list[str] = []
for c in codecs:
    for b in data[c]:
        if b not in all_builds:
            all_builds.append(b)

other_builds = sorted(b for b in all_builds if b != BASELINE)
builds = [BASELINE] + other_builds  # baseline always first column

# ── compute speedups ─────────────────────────────────────────────────────────
# speedup[codec][build] = baseline_time / build_time
speedup: dict[str, dict[str, float | None]] = {}
for codec in codecs:
    speedup[codec] = {}
    baseline_time = data[codec].get(BASELINE)
    for build in builds:
        build_time = data[codec].get(build)
        if baseline_time is None or build_time is None or build_time == 0:
            speedup[codec][build] = None
        else:
            speedup[codec][build] = baseline_time / build_time

# ── pretty-print ─────────────────────────────────────────────────────────────
col_w   = max(len(b) for b in builds) + 2   # column width
lbl_w   = max(len(c) for c in codecs) + 2   # codec label width

header = f"{'Codec':<{lbl_w}}" + "".join(f"{b:>{col_w}}" for b in builds)
sep    = "-" * len(header)

print(f"\nSpeedup relative to {BASELINE}  (>1 = faster than baseline)\n")
print(sep)
print(header)
print(sep)

for codec in codecs:
    row_str = f"{codec:<{lbl_w}}"
    for build in builds:
        val = speedup[codec][build]
        if val is None:
            cell = "N/A"
        elif build == BASELINE:
            cell = "1.000"          # baseline is always 1
        else:
            cell = f"{val:.3f}"
        row_str += f"{cell:>{col_w}}"
    print(row_str)

print(sep)

# ── geometric mean per build ──────────────────────────────────────────────────
import math

print(f"{'GeoMean':<{lbl_w}}", end="")
for build in builds:
    vals = [speedup[c][build] for c in codecs if speedup[c][build] is not None]
    if vals:
        geo = math.exp(sum(math.log(v) for v in vals) / len(vals))
        cell = "1.000" if build == BASELINE else f"{geo:.3f}"
    else:
        cell = "N/A"
    print(f"{cell:>{col_w}}", end="")
print()
print(sep)
print()

