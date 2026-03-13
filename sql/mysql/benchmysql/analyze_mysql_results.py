#!/usr/bin/env python3

import sys
import os
import csv

def read_csv_data(filepath):
    """
    Reads all data from a CSV file.

    Returns:
        A tuple containing the header (list of strings) and all rows (list of lists of strings).
        Returns (None, None) if the file cannot be read.
    """
    if not os.path.exists(filepath):
        print(f"Error: File not found at {filepath}", file=sys.stderr)
        return None, None

    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            reader = csv.reader(f)
            # Read header and clean it
            header = [h.strip() for h in next(reader) if h.strip()]
            # Read rows and clean them, skipping empty rows
            rows = [[cell.strip() for cell in row] for row in reader if any(cell.strip() for cell in row)]
        return header, rows
    except Exception as e:
        print(f"Error reading or parsing CSV file: {e}", file=sys.stderr)
        return None, None

def print_pretty_table(header, rows):
    """
    Prints a list of rows in a well-formatted table.
    """
    if not header or not rows:
        print("No data to display.")
        return

    normalized_rows = [
        row[:len(header)] + [''] * max(0, len(header) - len(row))
        for row in rows
    ]

    # 1. Calculate the maximum width for each column
    col_widths = [len(h) for h in header]
    for row in normalized_rows:
        for i, cell in enumerate(row):
            if len(cell) > col_widths[i]:
                col_widths[i] = len(cell)

    # 2. Create the format string for the header and rows
    # Example: "| {:<15} | {:<25} | ..."
    row_format = "| " + " | ".join([f"{{:<{w}}}" for w in col_widths]) + " |"

    # 3. Create the separator line
    # Example: "+-----------------+---------------------------+..."
    separator = "+-" + "-+-".join(["-" * w for w in col_widths]) + "-+"

    # 4. Print the table
    print(separator)
    print(row_format.format(*header))
    print(separator)

    for row in normalized_rows:
        print(row_format.format(*row))

    print(separator)


def build_sort_key(name):
    """
    Keep baseline configurations first, then sort the rest alphabetically.
    """
    if name == 'orig':
        return (0, name)
    if name == 'tsan':
        return (1, name)
    return (2, name)


def format_ratio(numerator, denominator, zero_fallback='N/A'):
    """
    Formats a ratio as '<value>x' and handles zero-denominator edge cases.
    """
    if denominator > 0:
        return f"{(numerator / denominator):.2f}x"
    return "1.00x" if numerator == 0 else zero_fallback


def load_summary_data(filepath):
    """
    Loads valid rows for summary generation and groups them by dataset and build.

    Returns:
        A tuple (grouped_data, skipped_rows).
    """
    grouped_data = {}
    skipped_rows = []

    with open(filepath, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        if not reader.fieldnames:
            raise ValueError('CSV file is missing a header row.')

        header = [h.strip() for h in reader.fieldnames]
        total_col_name = 'Total ops' if 'Total ops' in header else 'Total'

        required_columns = ['MySQL build', 'Sysbench script', 'Memory peak (kb)', total_col_name]
        missing_columns = [column for column in required_columns if column not in header]
        if missing_columns:
            raise KeyError(f"Missing required column(s): {', '.join(missing_columns)}")

        for line_number, row in enumerate(reader, start=2):
            if not row or not any((value or '').strip() for value in row.values()):
                continue

            build = (row.get('MySQL build') or '').strip()
            dataset = (row.get('Sysbench script') or '').strip()
            total_raw = (row.get(total_col_name) or '').strip()
            memory_raw = (row.get('Memory peak (kb)') or '').strip()

            if not build or not dataset or not total_raw or not memory_raw:
                skipped_rows.append(line_number)
                continue

            try:
                total_ops = float(total_raw)
                memory_peak = float(memory_raw)
            except ValueError:
                skipped_rows.append(line_number)
                continue

            grouped_data.setdefault(dataset, {})[build] = {
                'Total': total_ops,
                'Memory peak (kb)': memory_peak,
            }

    return grouped_data, skipped_rows


def process_and_print_summary(filepath):
    """
    Processes the CSV data to create summary tables with calculated metrics per dataset.
    """
    print("\n\n--- Performance and Memory Summary ---\n")

    try:
        grouped_data, skipped_rows = load_summary_data(filepath)
    except (IOError, ValueError, KeyError) as e:
        print(f"Error processing summary data: {e}", file=sys.stderr)
        return

    if skipped_rows:
        skipped_str = ', '.join(str(line_number) for line_number in skipped_rows)
        print(f"Warning: skipped malformed summary rows at line(s): {skipped_str}", file=sys.stderr)

    if not grouped_data:
        print("Error: no valid data rows found for summary generation.", file=sys.stderr)
        return

    summary_header = ['Configuration', 'Total ops', 'SD (Perf)', 'SU (Perf)', 'SD (Mem)', 'SU (Mem)']
    printed_any_dataset = False

    for dataset, data in grouped_data.items():
        orig_data = data.get('orig')
        tsan_data = data.get('tsan')

        if not orig_data or not tsan_data:
            missing = []
            if not orig_data:
                missing.append('orig')
            if not tsan_data:
                missing.append('tsan')
            missing_str = ', '.join(missing)
            print(
                f"Warning: dataset '{dataset}' is missing baseline configuration(s): {missing_str}. Skipping.",
                file=sys.stderr,
            )
            continue

        orig_total = orig_data['Total']
        tsan_total = tsan_data['Total']
        orig_mem = orig_data['Memory peak (kb)']
        tsan_mem = tsan_data['Memory peak (kb)']

        summary_rows = []
        for name, values in sorted(data.items(), key=lambda item: build_sort_key(item[0])):
            total_ops = values['Total']
            memory = values['Memory peak (kb)']

            sd_perf_str = format_ratio(orig_total, total_ops)
            su_perf_str = 'N/A' if name == 'orig' else format_ratio(total_ops, tsan_total)
            sd_mem_str = format_ratio(memory, orig_mem, zero_fallback='Inf')
            su_mem_str = 'N/A' if name == 'orig' else format_ratio(tsan_mem, memory, zero_fallback='Inf')

            summary_rows.append([
                name,
                f"{total_ops:.2f}",
                sd_perf_str,
                su_perf_str,
                sd_mem_str,
                su_mem_str,
            ])

        print(f"Dataset: {dataset}")
        print_pretty_table(summary_header, summary_rows)
        print()
        printed_any_dataset = True

    if not printed_any_dataset:
        print("Error: no dataset contained both 'orig' and 'tsan', so no summary tables were generated.", file=sys.stderr)


def main():
    """
    Main function.
    """
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <path_to_results.csv>", file=sys.stderr)
        sys.exit(1)

    filepath = sys.argv[1]

    # --- 1. Print the original raw data table ---
    print("--- Raw Data from CSV ---\n")
    header, rows = read_csv_data(filepath)
    if header and rows:
        print_pretty_table(header, rows)

    # --- 2. Print the calculated summary table ---
    process_and_print_summary(filepath)

if __name__ == "__main__":
    main()