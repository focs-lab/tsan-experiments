#!/usr/bin/env python3

import sys
import os
import re
import math
from collections import defaultdict

def parse_log_file(filepath):
    """
    Parses a single SQLite log file to extract performance metrics for each test.

    Returns:
        A dictionary {'test_name': value, ...}
    """
    metrics = defaultdict(float)
    current_test = None

    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            for line in f:
                # Check if a new test is starting
                match = re.search(r"Running (\S+) for", line)
                if match:
                    current_test = match.group(1)
                    continue

                if not current_test:
                    continue

                # --- Extract metrics based on the current test ---

                # walthread1: Sum of iterations
                if 'walthread1' in current_test:
                    m = re.search(r"(\d+) iterations", line)
                    if m: metrics[current_test] += float(m.group(1))

                # walthread2: Sum of writes
                elif 'walthread2' in current_test:
                    m = re.search(r"W (\d+) R \d+", line)
                    if m: metrics[current_test] += float(m.group(1))

                # dynamic_triggers: Sum of created and inserts
                elif 'dynamic_triggers' in current_test:
                    m_created = re.search(r"(\d+) created", line)
                    m_inserts = re.search(r"(\d+) inserts", line)
                    if m_created: metrics[current_test] += float(m_created.group(1))
                    if m_inserts: metrics[current_test] += float(m_inserts.group(1))

                # checkpoint_starvation: Transaction count
                elif 'checkpoint_starvation' in current_test:
                    m = re.search(r"Transaction count: (\d+)", line)
                    if m: metrics[current_test] = float(m.group(1))

                # stress1: Sum of successful writes and reads
                elif 'stress1' in current_test:
                    m_wrote = re.search(r"wrote t\d+ (\d+)/\d+", line)
                    m_read = re.search(r"read t\d+ (\d+)/\d+", line)
                    if m_wrote: metrics[current_test] += float(m_wrote.group(1))
                    if m_read: metrics[current_test] += float(m_read.group(1))

    except IOError as e:
        print(f"Error reading file {filepath}: {e}", file=sys.stderr)
        return {}

    return dict(metrics)

def analyze_directory(dir_path):
    """
    Finds all .log files in a directory, parses them, and returns the aggregated data.
    """
    if not os.path.isdir(dir_path):
        print(f"Error: Directory not found at {dir_path}", file=sys.stderr)
        return None

    all_data = {}
    for filename in os.listdir(dir_path):
        if filename.endswith(".log"):
            config_name = os.path.splitext(filename)[0]
            filepath = os.path.join(dir_path, filename)

            # Skip non-test logs
            if config_name in ["compilation_times", "instr_count"]:
                continue

            parsed_metrics = parse_log_file(filepath)
            if parsed_metrics:
                all_data[config_name] = parsed_metrics

    return all_data

def print_summary_table(all_data):
    """
    Calculates metrics and prints a summary table.
    """
    if not all_data:
        print("No data parsed to create a summary.")
        return

    native_results = all_data.get('orig')
    tsan_results = all_data.get('tsan')

    if not native_results:
        print("Error: 'orig.log' data not found. Cannot calculate Slowdown (SD).", file=sys.stderr)
        return
    if not tsan_results:
        print("Error: 'tsan.log' data not found. Cannot calculate Speedup (SU).", file=sys.stderr)
        return

    configs = sorted([c for c in all_data.keys() if c != 'orig'])
    all_tests = sorted(list(set(test for data in all_data.values() for test in data.keys())))

    # --- Print summary table ---
    header_width = 25
    print("\n" + "=" * 150)
    print("SQLite Performance Summary")
    print("SD: Slowdown vs. Native (lower is better). SU: Speedup vs. TSan (higher is better).")
    print("=" * 150)

    header = f"{'Test Case':<28}"
    for config in configs:
        header += f" | {config:<{header_width}}"
    print(header)
    print("-" * len(header))

    geomean_slowdowns = defaultdict(list)
    geomean_speedups = defaultdict(list)

    for test_name in all_tests:
        row_str = f"{test_name:<28}"
        native_value = native_results.get(test_name)
        tsan_value = tsan_results.get(test_name)

        for config in configs:
            config_data = all_data.get(config, {})
            bench_value = config_data.get(test_name)

            cell_str = "N/A"
            if bench_value is not None:
                # Calculate Slowdown (SD)
                if native_value and bench_value > 0:
                    slowdown = native_value / bench_value
                    sd_str = f"SD:{slowdown:>6.2f}x"
                    geomean_slowdowns[config].append(slowdown)
                else:
                    sd_str = f"SD:{'N/A':>7}"

                # Calculate Speedup (SU)
                if config != 'tsan' and tsan_value and bench_value > 0:
                    speedup = bench_value / tsan_value
                    su_str = f"SU:{speedup:>6.2f}x"
                    geomean_speedups[config].append(speedup)
                else:
                    su_str = f"SU:{'----':>7}"

                cell_str = f"{sd_str} {su_str}"

            row_str += f" | {cell_str:<{header_width}}"
        print(row_str)

    # --- Print Geomean summary row ---
    print("-" * len(header))
    summary_row_str = f"{'Geomean':<28}"
    for config in configs:
        slowdowns = geomean_slowdowns.get(config, [])
        sd_str = f"SD:{'N/A':>7}"
        if slowdowns:
            geomean_sd = math.exp(sum(math.log(s) for s in slowdowns) / len(slowdowns))
            sd_str = f"SD:{geomean_sd:>6.2f}x"

        speedups = geomean_speedups.get(config, [])
        su_str = f"SU:{'----':>7}"
        if speedups:
            geomean_su = math.exp(sum(math.log(s) for s in speedups) / len(speedups))
            su_str = f"SU:{geomean_su:>6.2f}x"

        cell_str = f"{sd_str} {su_str}"
        summary_row_str += f" | {cell_str:<{header_width}}"
    print(summary_row_str)

def main():
    """
    Main function.
    """
    results_dir = "results"
    if len(sys.argv) > 1:
        results_dir = sys.argv[1]

    all_data = analyze_directory(results_dir)

    if all_data:
        print_summary_table(all_data)

if __name__ == "__main__":
    main()