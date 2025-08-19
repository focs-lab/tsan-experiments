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

    # 1. Calculate the maximum width for each column
    col_widths = [len(h) for h in header]
    for row in rows:
        for i, cell in enumerate(row):
            # Ensure we don't get an index error if a row has fewer columns
            if i < len(col_widths):
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

    for row in rows:
        print(row_format.format(*row))

    print(separator)


def process_and_print_summary(filepath):
    """
    Processes the CSV data to create a summary table with calculated metrics.
    """
    print("\n\n--- Performance and Memory Summary ---\n")
    
    # Use DictReader for easy access to columns by name
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            # Store data in a dictionary keyed by the build name
            data = {row['MySQL build'].strip(): {
                        'Total': float(row['Total'].strip()),
                        'Memory peak (kb)': float(row['Memory peak (kb)'].strip())
                    } for row in reader if row}
    except (IOError, ValueError, KeyError) as e:
        print(f"Error processing summary data: {e}", file=sys.stderr)
        return

    orig_data = data.get('orig')
    tsan_data = data.get('tsan')

    if not orig_data:
        print("Error: 'orig' configuration not found. Cannot calculate Slowdown (SD).", file=sys.stderr)
        return
    if not tsan_data:
        print("Error: 'tsan' configuration not found. Cannot calculate Speedup (SU).", file=sys.stderr)
        return
        
    orig_total = orig_data['Total']
    tsan_total = tsan_data['Total']

    # Prepare data for the new summary table
    summary_header = ['Configuration', 'Total ops', 'Memory peak (kb)', 'Slowdown (SD)', 'Speedup (SU)']
    summary_rows = []

    for name, values in sorted(data.items()):
        total_ops = values['Total']
        memory = values['Memory peak (kb)']

        # Calculate Slowdown (SD) vs. 'orig'
        sd_str = f"{orig_total / total_ops:.2f}x" if total_ops > 0 else "N/A"

        # Calculate Speedup (SU) vs. 'tsan'
        if name == 'orig':
            su_str = "N/A"  # SU is not applicable for 'orig'
        elif tsan_total > 0:
            su_str = f"{total_ops / tsan_total:.2f}x"
        else:
            su_str = "N/A"
            
        summary_rows.append([
            name,
            f"{total_ops:.2f}",
            f"{memory:.0f}",
            sd_str,
            su_str
        ])
    
    # Print the new table using the existing pretty-print function
    print_pretty_table(summary_header, summary_rows)


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