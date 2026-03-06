#!/usr/bin/env python3
"""
Build a memory overhead table from summary_ffmpeg_benchmark.csv.
Shows max_mem_kb for every build and overhead relative to baseline (ffmpeg-tsan):
  overhead = config_mem / tsan_mem  (>1 means more memory than tsan)

Usage:
    python3 memory_table.py [path/to/summary_ffmpeg_benchmark.csv]
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
# codec -> build -> max_mem_kb
data: dict = {}
codec_order: list = []
build_order: list = []

with open(CSV_FILE, newline="") as f:
    reader = csv.DictReader(f)
    for row in reader:
        codec = row["Codec"].strip('"')
        build = row["FFBUILD"].strip('"')
        mem   = float(row["max_mem_kb"])
        if codec not in data:
            data[codec] = {}
            codec_order.append(codec)
        data[codec][build] = mem
        if build not in build_order:
            build_order.append(build)

# baseline first, then others sorted
other_builds = sorted(b for b in build_order if b != BASELINE)
builds = [BASELINE] + other_builds

# ── compute overhead factors ─────────────────────────────────────────────────
overhead: dict = {}
for codec in codec_order:
    overhead[codec] = {}
    baseline_mem = data[codec].get(BASELINE)
    for build in builds:
        build_mem = data[codec].get(build)
        if baseline_mem is None or build_mem is None or baseline_mem == 0:
            overhead[codec][build] = None
        else:
            overhead[codec][build] = build_mem / baseline_mem

# ── pretty-print ─────────────────────────────────────────────────────────────
lbl_w = max(len(c) for c in codec_order + ["Codec", "GeoMean"]) + 2
col_w = max(len(b) for b in builds) + 2

def fmt_overhead(val, build):
    if val is None:
        return "N/A"
    if build == BASELINE:
        return "1.000"
    return f"{val:.3f}"

def fmt_mem(val):
    """Format memory in MB for the raw table."""
    if val is None:
        return "N/A"
    return f"{val / 1024:.1f}"

# ── Table 1: overhead ratios ──────────────────────────────────────────────────
header = f"{'Codec':<{lbl_w}}" + "".join(f"{b:>{col_w}}" for b in builds)
sep    = "-" * len(header)

print(f"\nMemory overhead relative to '{BASELINE}'  (value > 1 means more memory than baseline)\n")
print(sep)
print(header)
print(sep)

for codec in codec_order:
    row_str = f"{codec:<{lbl_w}}" + "".join(
        f"{fmt_overhead(overhead[codec][b], b):>{col_w}}" for b in builds
    )
    print(row_str)

print(sep)

# geometric mean per build column
print(f"{'GeoMean':<{lbl_w}}", end="")
for build in builds:
    vals = [overhead[c][build] for c in codec_order if overhead[c].get(build) is not None]
    if vals:
        geo = math.exp(sum(math.log(v) for v in vals) / len(vals))
        cell = fmt_overhead(geo, build)
    else:
        cell = "N/A"
    print(f"{cell:>{col_w}}", end="")
print()
print(sep)

# ── Table 2: raw memory values (MB) ──────────────────────────────────────────
print(f"\nMax RSS memory (MB) per build\n")
print(sep)
print(header)
print(sep)

for codec in codec_order:
    row_str = f"{codec:<{lbl_w}}" + "".join(
        f"{fmt_mem(data[codec].get(b)):>{col_w}}" for b in builds
    )
    print(row_str)

print(sep)

# mean per build column
print(f"{'Mean':<{lbl_w}}", end="")
for build in builds:
    vals = [data[c][build] for c in codec_order if data[c].get(build) is not None]
    if vals:
        mean_val = sum(vals) / len(vals)
        cell = fmt_mem(mean_val)
    else:
        cell = "N/A"
    print(f"{cell:>{col_w}}", end="")
print()
print(sep)
print()

