#!/usr/bin/env python3
import sys
import argparse

def main():
    """
    Reads a log file, calculates total operations, sorts the data,
    and prints a percentage-based summary including source locations.
    """
    parser = argparse.ArgumentParser(
        description="Analyzes a log file to show the percentage contribution of each address to total I/O operations.",
        epilog="Example: python3 sort_stats.py my_app.log > analysis_summary.txt"
    )
    parser.add_argument(
        "input_file",
        help="The path to the log file to be analyzed."
    )
    args = parser.parse_args()

    try:
        with open(args.input_file, 'r') as f:
            lines = f.readlines()

        # --- Pass 1: Validate lines and calculate totals ---
        valid_data = []
        total_rw, total_w, total_r = 0, 0, 0

        for line_num, line in enumerate(lines, 1):
            if not line.strip():
                continue

            parts = line.split()
            # A valid line must have at least 6 columns
            if len(parts) < 6:
                continue

            try:
                rw_count = int(parts[1])
                w_count = int(parts[2])
                r_count = int(parts[3])
                int(parts[4])  # Validate SWMR flag is numeric

                total_rw += rw_count
                total_w += w_count
                total_r += r_count

                # Store the entire list of parts for the second pass
                valid_data.append(parts)
            except (ValueError, IndexError):
                # Silently ignore lines that don't match the expected numeric format
                continue

        # --- Sort the valid data by the total R/W column (index 1) ---
        sorted_data = sorted(valid_data, key=lambda p: int(p[1]), reverse=True)

        # --- Pass 2: Calculate percentages and print the formatted output ---

        # Define a flexible header string
        header = (
            f"{'Address':<18} "
            f"{'% R/W':>10} "
            f"{'% Writes':>11} "
            f"{'% Reads':>10}   "
            f"{'Source Locations'}"
        )
        print(header)
        print("-" * 120) # A wide separator for readability

        for parts in sorted_data:
            address = parts[0]
            rw_count = int(parts[1])
            w_count = int(parts[2])
            r_count = int(parts[3])

            # Re-join the source location parts (from the 6th element onwards)
            source_locations = ' '.join(parts[5:])

            # Calculate percentages, handling potential division by zero
            percent_rw = (rw_count / total_rw * 100) if total_rw > 0 else 0
            percent_w = (w_count / total_w * 100) if total_w > 0 else 0
            percent_r = (r_count / total_r * 100) if total_r > 0 else 0

            # Print the formatted line, including the source locations at the end
            print(
                f"{address:<18} "
                f"{percent_rw:>8.2f}% "
                f"{percent_w:>10.2f}% "
                f"{percent_r:>9.2f}%   "
                f"{source_locations}"
            )

        # Print a summary footer with the totals
        if total_rw > 0:
            print("-" * 120)
            print("Total Operations Summary:")
            print(f"  - Reads + Writes: {total_rw:,}")
            print(f"  - Writes:         {total_w:,}")
            print(f"  - Reads:          {total_r:,}")

    except FileNotFoundError:
        print(f"Error: The file '{args.input_file}' was not found.", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()