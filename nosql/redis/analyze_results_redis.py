#!/usr/bin/env python3

import sys
from collections import defaultdict
import os
import math

def parse_results(filepath):
    """
    Parses the results file and returns a dictionary with the data.
    Structure: {'config_name': {'benchmark_name': value, ...}, ...}
    """
    if not os.path.exists(filepath):
        print(f"Error: File not found at {filepath}", file=sys.stderr)
        sys.exit(1)

    data = defaultdict(dict)
    current_config = None

    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith('==>'):
                # ==> Testing <config_name>
                current_config = line.split(' ')[2]
            elif current_config:
                parts = line.split()
                if len(parts) == 2:
                    benchmark_name, value_str = parts
                    try:
                        value = float(value_str)
                        data[current_config][benchmark_name] = value
                    except ValueError:
                        print(f"Warning: could not read value for '{benchmark_name}' in configuration '{current_config}'.", file=sys.stderr)
    return data

def calculate_and_print_metrics(data):
    """
    Calculates and prints metrics based on the parsed data in a summary table.
    """
    native_results = data.get('orig')
    tsan_results = data.get('tsan')

    if not native_results:
        print("Error: Data for 'orig' (Native) not found. Cannot calculate slowdown.", file=sys.stderr)
        return
    if not tsan_results:
        print("Error: Data for 'tsan' not found. Cannot calculate speedup.", file=sys.stderr)
        return

    # Collect all configurations (except 'orig') and benchmarks
    configs = sorted([c for c in data.keys() if c != 'orig'])
    all_benchmarks = sorted(list(set(b for c in data.values() for b in c.keys())))

    # --- Print summary table ---
    print("=" * 120)
    print("Performance Metrics Summary Table")
    print("SD: Slowdown vs. Native (lower is better). SU: Speedup vs. TSan (higher is better).")
    print("=" * 120)

    # Format and print the table header
    header = f"{'Benchmark':<15}"
    for config in configs:
        header += f" | {config:<21}"
    print(header)
    print("-" * len(header))

    # To store values for geometric mean calculation
    geomean_slowdowns = defaultdict(list)
    geomean_speedups = defaultdict(list)

    # Print table rows for each benchmark
    for bench_name in all_benchmarks:
        row_str = f"{bench_name:<15}"
        native_value = native_results.get(bench_name)
        tsan_value = tsan_results.get(bench_name)

        for config in configs:
            config_data = data.get(config, {})
            bench_value = config_data.get(bench_name)

            cell_str = ""
            if bench_value is None:
                cell_str = "N/A"
            else:
                # Calculate SD (Slowdown)
                if native_value and bench_value > 0:
                    slowdown = native_value / bench_value
                    sd_str = f"SD:{slowdown:>6.2f}x"
                    geomean_slowdowns[config].append(slowdown)
                else:
                    sd_str = f"SD:{'N/A':>7}"

                # Calculate SU (Speedup)
                if config != 'tsan' and tsan_value and bench_value > 0:
                    speedup = bench_value / tsan_value
                    su_str = f"SU:{speedup:>6.2f}x"
                    geomean_speedups[config].append(speedup)
                else:
                    # For 'tsan', speedup is not calculated (it's the baseline)
                    su_str = f"SU:{'----':>7}"

                cell_str = f"{sd_str} {su_str}"

            row_str += f" | {cell_str:<20}"
        print(row_str)

    # --- Print summary row with Geometric Mean ---
    print("-" * len(header))
    summary_row_str = f"{'Geomean':<15}"
    for config in configs:
        # Calculate Geomean SD
        slowdowns = geomean_slowdowns[config]
        if slowdowns:
            # Use logs for numerical stability: exp(sum(log(x_i))/n)
            log_sum_sd = sum(math.log(s) for s in slowdowns)
            geomean_sd = math.exp(log_sum_sd / len(slowdowns))
            sd_str = f"SD:{geomean_sd:>6.2f}x"
        else:
            sd_str = f"SD:{'N/A':>7}"

        # Calculate Geomean SU
        speedups = geomean_speedups[config]
        if speedups:
            log_sum_su = sum(math.log(s) for s in speedups)
            geomean_su = math.exp(log_sum_su / len(speedups))
            su_str = f"SU:{geomean_su:>6.2f}x"
        else:
            su_str = f"SU:{'----':>7}"

        cell_str = f"{sd_str} {su_str}"
        summary_row_str += f" | {cell_str:<20}"
    print(summary_row_str)


def main():
    """
    Main function.
    """
    filepath = '__results_redis__/results.txt'
    data = parse_results(filepath)
    if data:
        calculate_and_print_metrics(data)

if __name__ == "__main__":
    main()