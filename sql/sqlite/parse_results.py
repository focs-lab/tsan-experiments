import os
import re
from collections import defaultdict
import glob

# --- Configuration ---
RESULTS_DIR = 'results'
# The non-instrumented baseline file (e.g., compiled with -O2)
NON_INSTRUMENTED_BASELINE_FILENAME = 'orig.log'
# The default TSan instrumentation baseline file
TSAN_BASELINE_FILENAME = 'tsan.txt'


def parse_log_file(filepath):
    """
    Parses a single log file and extracts performance metrics.
    Returns a dictionary of {'test_name': value}.
    """
    results = defaultdict(float)
    current_test = None

    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            # Determine which test section we are in
            match = re.search(r'^Running (\S+)', line)
            if match:
                current_test = match.group(1)
                # Initialize metric for the new test
                if current_test not in results:
                    results[current_test] = 0.0
                continue

            if not current_test:
                continue

            # --- Rules for extracting metrics for each test ---

            # walthread1: 345 iterations
            m = re.search(r'says: (\d+) iterations', line)
            if m and current_test == 'walthread1':
                results[current_test] += int(m.group(1))
                continue

            # walthread2: W 1825 R 0
            m = re.search(r'says: W (\d+) R (\d+)', line)
            if m and current_test == 'walthread2':
                results[current_test] += int(m.group(1)) + int(m.group(2))
                continue

            # dynamic_triggers: 38500 inserts, 38500 deletes
            m = re.search(r'says: (\d+) inserts, (\d+) deletes', line)
            if m and current_test == 'dynamic_triggers':
                results[current_test] += int(m.group(1)) + int(m.group(2))
                continue

            # checkpoint_starvation_1, checkpoint_starvation_2
            m = re.search(r'Transaction count: (\d+) transactions', line)
            if m and 'checkpoint_starvation' in current_test:
                results[current_test] = int(m.group(1))
                continue

            # stress1: Measure 'wrote t1' operations only, as they represent the core workload.
            # Deleters can spin and inflate metrics artificially in instrumented builds.
            m = re.search(r'wrote t1 (\d+)/\d+ attempts', line)
            if m and current_test == 'stress1':
                results[current_test] += int(m.group(1))
                continue

            # stress2: ok 8752/17265
            m = re.search(r'says: ok (\d+)/\d+', line)
            if m and current_test == 'stress2':
                results[current_test] += int(m.group(1))
                continue

            # walthread5: WAL file is X bytes. We care about the final size.
            # m = re.search(r'WAL file is (-?\d+) bytes,', line)
            # if m and current_test == 'walthread5':
            #     results[current_test] = int(m.group(1))
            #     continue

    # Remove tests that did not yield a numerical metric
    #return {k: v for k, v in results.items() if v != 0.0 or k == 'walthread5'}
    return {k: v for k, v in results.items() if v != 0.0}


def generate_comparison_tables(all_data):
    """
    Builds and prints two comparison tables:
    1. Slowdown of all configs vs. the non-instrumented baseline.
    2. Speedup of optimized TSan configs vs. the default TSan baseline.
    """
    non_instr_conf_name = os.path.splitext(NON_INSTRUMENTED_BASELINE_FILENAME)[0]
    tsan_conf_name = os.path.splitext(TSAN_BASELINE_FILENAME)[0]

    # --- Table 1: Slowdown vs. Non-Instrumented Baseline ---
    if non_instr_conf_name not in all_data:
        print(f"\nWarning: Non-instrumented baseline file '{NON_INSTRUMENTED_BASELINE_FILENAME}' not found. Skipping slowdown table.")
    else:
        print(f"\n--- Table 1: Performance Slowdown vs. Baseline ('{non_instr_conf_name}') ---")
        baseline_results = all_data[non_instr_conf_name]
        configs_to_compare = sorted([name for name in all_data if name != non_instr_conf_name])
        all_tests = sorted(list(set(k for res in all_data.values() for k in res.keys())))

        header = f"{'Test Case':<25}" + "".join([f"{name:<28}" for name in configs_to_compare])
        print(header)
        print("-" * len(header))

        for test in all_tests:
            row = [f"{test:<25}"]
            baseline_val = baseline_results.get(test)

            for name in configs_to_compare:
                val = all_data[name].get(test)
                cell_str = "N/A"

                if val is not None and baseline_val is not None:
                    # For walthread5, smaller is better. A direct comparison is more useful.
                    # if test == 'walthread5':
                    #     cell_str = f"{int(val):,} (base: {int(baseline_val):,})"
                    # For all other tests, higher ops is better.
                    if val > 0:
                        slowdown = baseline_val / val
                        cell_str = f"{int(val):,} ({slowdown:.2f}x slowdown)"
                    else:
                        cell_str = f"{int(val):,}"
                row.append(f"{cell_str:<28}")

            print("".join(row))

    # --- Table 2: Speedup vs. Default TSan Baseline ---
    if tsan_conf_name not in all_data:
        print(f"\nWarning: TSan baseline file '{TSAN_BASELINE_FILENAME}' not found. Skipping speedup table.")
    else:
        print(f"\n--- Table 2: Optimized TSan Speedup vs. Default ('{tsan_conf_name}') ---")
        tsan_baseline_results = all_data[tsan_conf_name]
        # Compare only configs starting with 'tsan-' but are not the baseline itself
        tsan_configs_to_compare = sorted([
            name for name in all_data if name.startswith(tsan_conf_name + '-')
        ])

        if not tsan_configs_to_compare:
            print("No optimized TSan configurations (e.g., 'tsan-*') found to compare.")
            return

        all_tests = sorted(list(set(k for res in all_data.values() for k in res.keys())))

        header = f"{'Test Case':<25}" + "".join([f"{name:<28}" for name in tsan_configs_to_compare])
        print(header)
        print("-" * len(header))

        for test in all_tests:
            row = [f"{test:<25}"]
            tsan_baseline_val = tsan_baseline_results.get(test)

            for name in tsan_configs_to_compare:
                val = all_data[name].get(test)
                cell_str = "N/A"

                if val is not None and tsan_baseline_val is not None:
                    # For walthread5, smaller is better, so speedup is inverted.
                    # if test == 'walthread5' and val > 0:
                    #     speedup = tsan_baseline_val / val if tsan_baseline_val > 0 else float('inf')
                    #     cell_str = f"{int(val):,} ({speedup:.2f}x speedup)"
                    # For other tests, higher ops is better.
                    if tsan_baseline_val > 0:
                        speedup = val / tsan_baseline_val
                        cell_str = f"{int(val):,} ({speedup:.2f}x speedup)"
                    else:
                        cell_str = f"{int(val):,}"

                row.append(f"{cell_str:<28}")

            print("".join(row))


def main():
    """
    Main function: finds files, parses them, and prints comparison tables.
    """
    log_files = glob.glob(os.path.join(RESULTS_DIR, '*.log'))
    if not log_files:
        print(f"Error: No result files found in the '{RESULTS_DIR}' directory.")
        return

    all_data = {}
    for f in log_files:
        conf_name = os.path.splitext(os.path.basename(f))[0]
        print(f"Parsing file: {f} (config: {conf_name})")
        all_data[conf_name] = parse_log_file(f)

    generate_comparison_tables(all_data)


if __name__ == "__main__":
    main()