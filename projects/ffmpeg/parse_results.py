#!/usr/bin/env python3
"""
Build a speedup table from summary_ffmpeg_benchmark.csv.
Speedup = tsan_mean_time / config_mean_time  (>1 means faster than tsan).
Baseline build: "ffmpeg-tsan"

Usage:
    python3 speedup_table.py [path/to/summary_ffmpeg_benchmark.csv]
"""

import csv
import math
import sys
from pathlib import Path

BASELINE = "ffmpeg-tsan"

# CSV file: first CLI arg, or same directory as this script
if len(sys.argv) > 1:
    CSV_FILE = Path(sys.argv[1])
else:
    CSV_FILE = Path(__file__).resolve().parent / "summary_ffmpeg_benchmark.csv"

# ── load data ────────────────────────────────────────────────────────────────
# codec -> build -> mean_time_s
data: dict = {}
codec_order: list = []
build_order: list = []

with open(CSV_FILE, newline="") as f:
    reader = csv.DictReader(f)
    for row in reader:
        codec = row["Codec"].strip('"')
        build = row["FFBUILD"].strip('"')
        mean  = float(row["mean_time_s"])
        if codec not in data:
            data[codec] = {}
            codec_order.append(codec)
        data[codec][build] = mean
        if build not in build_order:
            build_order.append(build)

# baseline first, then others sorted
other_builds = sorted(b for b in build_order if b != BASELINE)
builds = [BASELINE] + other_builds

# ── compute speedups ─────────────────────────────────────────────────────────
speedup: dict = {}
for codec in codec_order:
    speedup[codec] = {}
    baseline_time = data[codec].get(BASELINE)
    for build in builds:
        build_time = data[codec].get(build)
        if baseline_time is None or build_time is None or build_time == 0:
            speedup[codec][build] = None
        else:
            speedup[codec][build] = baseline_time / build_time

# ── pretty-print ─────────────────────────────────────────────────────────────
lbl_w = max(len(c) for c in codec_order + ["Codec", "GeoMean"]) + 2
col_w = max(len(b) for b in builds) + 2

def fmt(val, build):
    if val is None:
        return "N/A"
    if build == BASELINE:
        return "1.000"
    return f"{val:.3f}"

header = f"{'Codec':<{lbl_w}}" + "".join(f"{b:>{col_w}}" for b in builds)
sep    = "-" * len(header)

print(f"\nSpeedup relative to '{BASELINE}'  (value > 1 means faster than baseline)\n")
print(sep)
print(header)
print(sep)

for codec in codec_order:
    row_str = f"{codec:<{lbl_w}}" + "".join(
        f"{fmt(speedup[codec][b], b):>{col_w}}" for b in builds
    )
    print(row_str)

print(sep)

# geometric mean per build column
print(f"{'GeoMean':<{lbl_w}}", end="")
for build in builds:
    vals = [speedup[c][build] for c in codec_order if speedup[c].get(build) is not None]
    if vals:
        geo = math.exp(sum(math.log(v) for v in vals) / len(vals))
        cell = fmt(geo, build)
    else:
        cell = "N/A"
    print(f"{cell:>{col_w}}", end="")
print()
print(sep)
print()

