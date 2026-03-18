#!/usr/bin/env python3
r"""Aggregate FFmpeg contention benchmark runs and generate CSV + PGFPlots output.

The script scans ``results_threads-*`` directories, loads per-thread benchmark summaries,
computes speedup relative to a baseline build (default: ``ffmpeg-tsan``), writes a
normalized CSV dataset, and emits a LaTeX/PGFPlots ``groupplot`` figure that can be
``\input{}`` into a paper.

Primary input is ``summary_ffmpeg_benchmark.json``. If JSON is absent, the script falls
back to ``summary_ffmpeg_benchmark.csv`` and only parses the columns needed for plotting.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_RESULTS_GLOB = "results_threads-*"
DEFAULT_BASELINE = "ffmpeg-tsan"
DEFAULT_OUTPUT_PREFIX = "ffmpeg_contention"
DEFAULT_FIGURE_CAPTION = "FFmpeg Runtime Performance under Contention: Speedup (SU) vs. Original TSan."
DEFAULT_FIGURE_LABEL = "fig:results_runtime_ffmpeg_contention"
DEFAULT_LEGEND_NAME = "ffmpegcontentionlegend"

PREFERRED_CODEC_ORDER = [
    "mjpeg",
    "h264_libx264",
    "h265_libx265",
    "copy_passthrough",
]

PREFERRED_BUILD_ORDER = [
    "ffmpeg-tsan-dom",
    "ffmpeg-tsan-dom_peeling",
    "ffmpeg-tsan-ea",
    "ffmpeg-tsan-lo",
    "ffmpeg-tsan-loub",
    "ffmpeg-tsan-st",
    "ffmpeg-tsan-stmt",
    "ffmpeg-tsan-swmr",
    "ffmpeg-tsan-dom_peeling-ea-lo-st-swmr",
    "ffmpeg-tsan-dom_peeling-ea-lo-st-swmr-stmt",
    "ffmpeg-orig",
    "ffmpeg-tsan",
]

BUILD_LABELS = {
    "ffmpeg-orig": "Original FFmpeg",
    "ffmpeg-tsan": "Original TSan",
    "ffmpeg-tsan-dom": "TSan+DE",
    "ffmpeg-tsan-dom_peeling": "TSan+DE+Peeling",
    "ffmpeg-tsan-ea": "TSan+EA",
    "ffmpeg-tsan-lo": "TSan+LO",
    "ffmpeg-tsan-loub": "TSan+LO-UB",
    "ffmpeg-tsan-st": "TSan+STC",
    "ffmpeg-tsan-stmt": "TSan+DynSTC",
    "ffmpeg-tsan-swmr": "TSan+SWMR",
    "ffmpeg-tsan-dom_peeling-ea-lo-st-swmr": "TSan All",
    "ffmpeg-tsan-dom_peeling-ea-lo-st-swmr-stmt": "TSan All+DynSTC",
}

BUILD_STYLES = {
    "ffmpeg-tsan-dom": "mark=triangle*, color=blue, dashed",
    "ffmpeg-tsan-dom_peeling": "mark=square*, color=orange!85!black, densely dashed",
    "ffmpeg-tsan-ea": "mark=pentagon*, color=cyan, densely dotted",
    "ffmpeg-tsan-lo": "mark=*, color=green!60!black, dash dot",
    "ffmpeg-tsan-loub": "mark=otimes*, color=magenta!80!black, densely dashdotdotted",
    "ffmpeg-tsan-st": "mark=diamond*, color=purple, dash dot dot",
    "ffmpeg-tsan-stmt": "mark=x, color=red!80!black, densely dashdotted",
    "ffmpeg-tsan-swmr": "mark=star, color=brown, loosely dashed",
    "ffmpeg-tsan-dom_peeling-ea-lo-st-swmr": "mark=o, color=black, solid",
    "ffmpeg-tsan-dom_peeling-ea-lo-st-swmr-stmt": "mark=asterisk, color=gray!70!black, solid",
    "ffmpeg-orig": "mark=+, color=teal!70!black, densely dotted",
    "ffmpeg-tsan": "mark=none, color=gray, densely dashed",
}

FALLBACK_STYLES = [
    "mark=triangle*, color=blue, dashed",
    "mark=square*, color=orange!85!black, densely dashed",
    "mark=pentagon*, color=cyan, densely dotted",
    "mark=*, color=green!60!black, dash dot",
    "mark=diamond*, color=purple, dash dot dot",
    "mark=x, color=red!80!black, densely dashdotted",
    "mark=star, color=brown, loosely dashed",
    "mark=o, color=black, solid",
    "mark=+, color=teal!70!black, densely dotted",
    "mark=oplus*, color=violet, dash pattern=on 3pt off 2pt",
]

CODEC_TITLES = {
    "mjpeg": "MJPEG codec",
    "h264_libx264": "H.264 / libx264",
    "h265_libx265": "H.265 / libx265",
    "copy_passthrough": "Passthrough copy",
}


@dataclass(frozen=True)
class BenchmarkRecord:
    threads: int
    codec: str
    build: str
    mean_time_s: float
    stddev_time_s: float
    min_time_s: float
    max_time_s: float
    mean_user_s: float
    mean_system_s: float
    max_mem_kb: float
    runs_successful: int
    runs_total: int
    source_file: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=SCRIPT_DIR,
        help="Directory containing results_threads-* folders (default: script directory).",
    )
    parser.add_argument(
        "--results-glob",
        default=DEFAULT_RESULTS_GLOB,
        help=f"Glob used to find per-thread results directories (default: {DEFAULT_RESULTS_GLOB!r}).",
    )
    parser.add_argument(
        "--baseline-build",
        default=DEFAULT_BASELINE,
        help=f"Build used as speedup baseline (default: {DEFAULT_BASELINE!r}).",
    )
    parser.add_argument(
        "--build",
        action="append",
        default=[],
        help="Build to include in the plot. Repeat to control order. Defaults to all non-baseline, non-orig builds found.",
    )
    parser.add_argument(
        "--codec",
        action="append",
        default=[],
        help="Codec to include in the plot. Repeat to control order. Defaults to all codecs found.",
    )
    parser.add_argument(
        "--include-baseline",
        action="store_true",
        help="Also plot the baseline build as a flat y=1 line.",
    )
    parser.add_argument(
        "--include-orig",
        action="store_true",
        help="Include ffmpeg-orig in the plot if present.",
    )
    parser.add_argument(
        "--output-prefix",
        type=Path,
        default=SCRIPT_DIR / DEFAULT_OUTPUT_PREFIX,
        help="Prefix for generated files, e.g. /tmp/foo -> /tmp/foo_speedup.csv and /tmp/foo_speedup.tex.",
    )
    parser.add_argument(
        "--caption",
        default=DEFAULT_FIGURE_CAPTION,
        help="Figure caption for generated LaTeX.",
    )
    parser.add_argument(
        "--label",
        default=DEFAULT_FIGURE_LABEL,
        help="Figure label for generated LaTeX.",
    )
    parser.add_argument(
        "--legend-columns",
        type=int,
        default=-1,
        help="Legend columns for PGFPlots (default: -1, one row if possible).",
    )
    return parser.parse_args()


def latex_escape(text: str) -> str:
    replacements = {
        "\\": r"\\textbackslash{}",
        "&": r"\\&",
        "%": r"\\%",
        "$": r"\\$",
        "#": r"\\#",
        "_": r"\\_",
        "{": r"\\{",
        "}": r"\\}",
    }
    return "".join(replacements.get(ch, ch) for ch in text)


def parse_runs_completed(value: str) -> tuple[int, int]:
    match = re.fullmatch(r"\s*(\d+)\s*/\s*(\d+)\s*", value)
    if not match:
        raise ValueError(f"Invalid runs_completed value: {value!r}")
    return int(match.group(1)), int(match.group(2))


def sort_by_preference(items: Iterable[str], preferred_order: list[str]) -> list[str]:
    items = list(dict.fromkeys(items))
    preferred_index = {name: idx for idx, name in enumerate(preferred_order)}
    return sorted(items, key=lambda item: (preferred_index.get(item, len(preferred_order)), item))


def iter_result_dirs(root: Path, pattern: str) -> list[tuple[int, Path]]:
    result_dirs: list[tuple[int, Path]] = []
    for path in root.glob(pattern):
        if not path.is_dir():
            continue
        match = re.search(r"results_threads-(\d+)$", path.name)
        if not match:
            continue
        result_dirs.append((int(match.group(1)), path))
    result_dirs.sort(key=lambda item: item[0])
    return result_dirs


def load_summary_json(summary_json: Path, threads: int) -> list[BenchmarkRecord]:
    payload = json.loads(summary_json.read_text())
    benchmarks = payload.get("benchmarks", [])
    records: list[BenchmarkRecord] = []
    for entry in benchmarks:
        runs = entry.get("runs", {})
        time_info = entry.get("time", {})
        cpu_info = entry.get("cpu", {})
        memory_info = entry.get("memory", {})
        records.append(
            BenchmarkRecord(
                threads=threads,
                codec=entry["codec"],
                build=entry["build"],
                mean_time_s=float(time_info["mean_s"]),
                stddev_time_s=float(time_info.get("stddev_s", 0.0)),
                min_time_s=float(time_info.get("min_s", time_info["mean_s"])),
                max_time_s=float(time_info.get("max_s", time_info["mean_s"])),
                mean_user_s=float(cpu_info.get("mean_user_s", 0.0)),
                mean_system_s=float(cpu_info.get("mean_system_s", 0.0)),
                max_mem_kb=float(memory_info.get("max_peak_kb", 0.0)),
                runs_successful=int(runs.get("successful", 0)),
                runs_total=int(runs.get("total", 0)),
                source_file=str(summary_json),
            )
        )
    return records


def load_summary_csv(summary_csv: Path, threads: int) -> list[BenchmarkRecord]:
    records: list[BenchmarkRecord] = []
    with summary_csv.open(newline="") as handle:
        header = handle.readline()
        if not header:
            return records
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue
            parts = line.split(",", 10)
            if len(parts) < 10:
                raise ValueError(f"Malformed CSV line in {summary_csv}: {line!r}")
            codec = parts[0].strip().strip('"')
            build = parts[1].strip().strip('"')
            runs_successful, runs_total = parse_runs_completed(parts[2].strip().strip('"'))
            mean_time_s = float(parts[3])
            stddev_time_s = float(parts[4])
            min_time_s = float(parts[5])
            max_time_s = float(parts[6])
            mean_user_s = float(parts[7])
            mean_system_s = float(parts[8])
            max_mem_kb = float(parts[9])
            records.append(
                BenchmarkRecord(
                    threads=threads,
                    codec=codec,
                    build=build,
                    mean_time_s=mean_time_s,
                    stddev_time_s=stddev_time_s,
                    min_time_s=min_time_s,
                    max_time_s=max_time_s,
                    mean_user_s=mean_user_s,
                    mean_system_s=mean_system_s,
                    max_mem_kb=max_mem_kb,
                    runs_successful=runs_successful,
                    runs_total=runs_total,
                    source_file=str(summary_csv),
                )
            )
    return records


def load_records(root: Path, pattern: str) -> list[BenchmarkRecord]:
    all_records: list[BenchmarkRecord] = []
    for threads, result_dir in iter_result_dirs(root, pattern):
        summary_json = result_dir / "summary_ffmpeg_benchmark.json"
        summary_csv = result_dir / "summary_ffmpeg_benchmark.csv"
        if summary_json.exists():
            all_records.extend(load_summary_json(summary_json, threads))
        elif summary_csv.exists():
            all_records.extend(load_summary_csv(summary_csv, threads))
        else:
            print(f"warning: no summary file found in {result_dir}", file=sys.stderr)
    return all_records


def pick_codecs(records: list[BenchmarkRecord], cli_codecs: list[str]) -> list[str]:
    discovered = sort_by_preference({record.codec for record in records}, PREFERRED_CODEC_ORDER)
    if cli_codecs:
        seen = {record.codec for record in records}
        missing = [codec for codec in cli_codecs if codec not in seen]
        if missing:
            raise SystemExit(f"Requested codec(s) not found: {', '.join(missing)}")
        return cli_codecs
    return discovered


def pick_builds(records: list[BenchmarkRecord], args: argparse.Namespace) -> list[str]:
    discovered = sort_by_preference({record.build for record in records}, PREFERRED_BUILD_ORDER)
    if args.build:
        seen = {record.build for record in records}
        missing = [build for build in args.build if build not in seen]
        if missing:
            raise SystemExit(f"Requested build(s) not found: {', '.join(missing)}")
        return args.build

    builds = []
    for build in discovered:
        if build == args.baseline_build and not args.include_baseline:
            continue
        if build == "ffmpeg-orig" and not args.include_orig:
            continue
        builds.append(build)
    return builds


def build_speedup_rows(records: list[BenchmarkRecord], baseline_build: str) -> list[dict[str, object]]:
    baseline_by_key: dict[tuple[int, str], BenchmarkRecord] = {}
    for record in records:
        if record.build == baseline_build:
            baseline_by_key[(record.threads, record.codec)] = record

    rows: list[dict[str, object]] = []
    for record in sorted(records, key=lambda r: (r.threads, r.codec, r.build)):
        baseline = baseline_by_key.get((record.threads, record.codec))
        baseline_time = baseline.mean_time_s if baseline else None
        speedup = None
        if baseline_time and record.mean_time_s:
            speedup = baseline_time / record.mean_time_s
        rows.append(
            {
                "threads": record.threads,
                "codec": record.codec,
                "build": record.build,
                "mean_time_s": record.mean_time_s,
                "stddev_time_s": record.stddev_time_s,
                "min_time_s": record.min_time_s,
                "max_time_s": record.max_time_s,
                "mean_user_s": record.mean_user_s,
                "mean_system_s": record.mean_system_s,
                "max_mem_kb": record.max_mem_kb,
                "runs_successful": record.runs_successful,
                "runs_total": record.runs_total,
                "baseline_build": baseline_build,
                "baseline_time_s": baseline_time,
                "speedup_vs_baseline": speedup,
                "source_file": record.source_file,
            }
        )
    return rows


def write_speedup_csv(rows: list[dict[str, object]], output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "threads",
        "codec",
        "build",
        "mean_time_s",
        "stddev_time_s",
        "min_time_s",
        "max_time_s",
        "mean_user_s",
        "mean_system_s",
        "max_mem_kb",
        "runs_successful",
        "runs_total",
        "baseline_build",
        "baseline_time_s",
        "speedup_vs_baseline",
        "source_file",
    ]
    with output_path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def nice_tick_step(span: float) -> float:
    candidates = [0.01, 0.02, 0.05, 0.1, 0.2, 0.25, 0.5, 1.0]
    target = span / 6.0 if span > 0 else 0.05
    for candidate in candidates:
        if candidate >= target:
            return candidate
    return candidates[-1]


def axis_limits(values: list[float]) -> tuple[float, float, float]:
    if not values:
        return 0.95, 1.05, 0.02
    min_val = min(values + [1.0])
    max_val = max(values + [1.0])
    span = max_val - min_val
    padding = max(span * 0.08, 0.02 if max_val <= 1.5 else 0.05)
    lower = max(0.0, min_val - padding)
    upper = max_val + padding
    step = nice_tick_step(upper - lower)
    ymin = math.floor(lower / step) * step
    ymax = math.ceil(upper / step) * step
    if math.isclose(ymin, ymax):
        ymax = ymin + step
    return round(ymin, 4), round(ymax, 4), step


def pgf_coordinates(points: list[tuple[int, float]]) -> str:
    return " ".join(f"({threads},{value:.4f})" for threads, value in points)


def xtick_values(threads: list[int]) -> list[int]:
    if len(threads) <= 10:
        return threads
    ticks = threads[::2]
    if ticks[-1] != threads[-1]:
        ticks.append(threads[-1])
    return ticks


def build_to_style(build: str, used_fallbacks: dict[str, str]) -> str:
    if build in BUILD_STYLES:
        return BUILD_STYLES[build]
    if build not in used_fallbacks:
        used_fallbacks[build] = FALLBACK_STYLES[len(used_fallbacks) % len(FALLBACK_STYLES)]
    return used_fallbacks[build]


def build_to_label(build: str) -> str:
    return BUILD_LABELS.get(build, build)


def codec_to_title(codec: str) -> str:
    return CODEC_TITLES.get(codec, codec)


def render_tex(rows: list[dict[str, object]], codecs: list[str], builds: list[str], args: argparse.Namespace) -> str:
    rows_by_codec_build: dict[tuple[str, str], list[tuple[int, float]]] = defaultdict(list)
    all_threads = sorted({int(row["threads"]) for row in rows})
    used_fallbacks: dict[str, str] = {}

    for row in rows:
        speedup = row["speedup_vs_baseline"]
        if speedup is None:
            continue
        codec = str(row["codec"])
        build = str(row["build"])
        if codec not in codecs or build not in builds:
            continue
        rows_by_codec_build[(codec, build)].append((int(row["threads"]), float(speedup)))

    xticks = xtick_values(all_threads)
    group_columns = 2 if len(codecs) == 4 else min(3, max(1, len(codecs)))
    group_rows = math.ceil(len(codecs) / group_columns)
    plot_width = {1: r"0.95\textwidth", 2: r"0.47\textwidth", 3: r"0.32\textwidth"}[group_columns]
    legend_columns = args.legend_columns if args.legend_columns != -1 else min(len(builds), 5)

    lines: list[str] = []
    lines.append("% Auto-generated by ffmpeg_contention_report.py")
    lines.append(r"\pgfplotsset{")
    lines.append(r"    myplotstyle/.style={")
    lines.append(f"        xtick={{{','.join(str(x) for x in xticks)}}},")
    lines.append(r"        grid=major,")
    lines.append(r"        ymajorgrids=true,")
    lines.append(r"        line width=1pt,")
    lines.append(f"        width={plot_width},")
    lines.append(r"        height=5.4cm,")
    lines.append(r"        xlabel={Threads},")
    lines.append(r"        ylabel={Speedup},")
    lines.append(r"        ylabel near ticks,")
    lines.append(r"        ylabel shift = -5pt,")
    lines.append(r"        xlabel near ticks,")
    lines.append(r"        label style={font=\small},")
    lines.append(r"        tick label style={font=\footnotesize},")
    lines.append(r"        title style={font=\small\bfseries},")
    lines.append(r"    }")
    lines.append(r"}")
    lines.append("")
    lines.append(r"\begin{figure}")
    lines.append(r"\centering")
    lines.append(r"\begin{tikzpicture}")
    lines.append(r"    \begin{groupplot}[")
    lines.append(r"        group style={")
    lines.append(f"            group size={group_columns} by {group_rows},")
    lines.append(r"            horizontal sep=1.4cm,")
    lines.append(r"            vertical sep=1.8cm,")
    lines.append(r"        },")
    lines.append(r"    ]")
    lines.append("")

    legend_plot_index = 0
    for codec_index, codec in enumerate(codecs):
        codec_values = [
            value
            for build in builds
            for _, value in rows_by_codec_build.get((codec, build), [])
        ]
        ymin, ymax, ytick = axis_limits(codec_values)
        plot_header = [
            r"    \nextgroupplot[",
            f"        title={{{latex_escape(codec_to_title(codec))}}},",
            f"        xmin={all_threads[0]}, xmax={all_threads[-1]},",
            f"        ymin={ymin:.4f}, ymax={ymax:.4f}, ytick distance={ytick:.4f},",
            r"        myplotstyle,",
        ]
        if codec_index == legend_plot_index:
            plot_header.extend(
                [
                    f"        legend columns={legend_columns},",
                    r"        legend style={",
                    r"            at={(0.5,-0.32)},",
                    r"            anchor=north,",
                    r"            nodes={scale=0.8, transform shape},",
                    r"            /tikz/every even column/.append style={column sep=0.12cm}",
                    r"        },",
                    f"        legend to name={DEFAULT_LEGEND_NAME},",
                ]
            )
        plot_header.append(r"    ]")
        lines.extend(plot_header)

        for build in builds:
            points = sorted(rows_by_codec_build.get((codec, build), []))
            if not points:
                continue
            style = build_to_style(build, used_fallbacks)
            lines.append(f"    \\addplot+[{{{style}}}] coordinates {{{pgf_coordinates(points)}}};")
            if codec_index == legend_plot_index:
                lines.append(f"    \\addlegendentry{{{latex_escape(build_to_label(build))}}};")
        lines.append("")

    lines.append(r"    \end{groupplot}")
    lines.append(r"\end{tikzpicture}")
    lines.append("")
    lines.append(f"\\pgfplotslegendfromname{{{DEFAULT_LEGEND_NAME}}}")
    lines.append("")
    lines.append(f"\\caption{{{latex_escape(args.caption)}}}")
    lines.append(f"\\label{{{args.label}}}")
    lines.append("")
    lines.append(r"\end{figure}")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    root = args.root.resolve()
    records = load_records(root, args.results_glob)
    if not records:
        raise SystemExit(f"No benchmark records found under {root}")

    codecs = pick_codecs(records, args.codec)
    builds = pick_builds(records, args)
    if not codecs:
        raise SystemExit("No codecs selected for plotting")
    if not builds:
        raise SystemExit("No builds selected for plotting")

    rows = build_speedup_rows(records, args.baseline_build)
    csv_out = Path(f"{args.output_prefix}_speedup.csv")
    tex_out = Path(f"{args.output_prefix}_speedup.tex")

    write_speedup_csv(rows, csv_out)
    tex_out.parent.mkdir(parents=True, exist_ok=True)
    tex_out.write_text(render_tex(rows, codecs, builds, args))

    selected_rows = [
        row for row in rows if row["codec"] in codecs and row["build"] in builds and row["speedup_vs_baseline"] is not None
    ]
    codecs_str = ", ".join(codecs)
    builds_str = ", ".join(builds)
    print(f"Loaded {len(records)} benchmark records from {root}")
    print(f"Selected codecs: {codecs_str}")
    print(f"Selected builds: {builds_str}")
    print(f"Rows contributing to the plot: {len(selected_rows)}")
    print(f"Wrote CSV: {csv_out}")
    print(f"Wrote TeX: {tex_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())



