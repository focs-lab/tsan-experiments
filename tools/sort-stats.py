#!/usr/bin/env python3
import sys
import argparse

def main():
    """
    Main function to parse arguments and sort the log file based on specific format.
    """
    parser = argparse.ArgumentParser(
        description="Sorts a log file numerically by its second column in descending order. "
                    "Only processes lines that match the expected format.",
        epilog="Example: python3 sort_log.py my_app.log > sorted.log"
    )
    parser.add_argument(
        "input_file",
        help="The path to the log file to be sorted."
    )
    args = parser.parse_args()

    try:
        with open(args.input_file, 'r') as f:
            lines = f.readlines()

        valid_lines = []
        for line_num, line in enumerate(lines, 1):
            # Skip empty or whitespace-only lines
            if not line.strip():
                continue

            parts = line.split()

            # --- Stricter Format Validation ---
            # A valid line must have at least 6 columns.
            if len(parts) < 6:
                print(f"Warning: Skipping line #{line_num} (expected at least 6 columns, found {len(parts)}): {line.strip()}", file=sys.stderr)
                continue

            # Columns 2, 3, 4, and 5 must be integers.
            try:
                # Check fields 1 through 4 (the four numeric counts)
                for i in range(1, 5):
                    int(parts[i])
            except ValueError:
                # This will catch the first part that is not an integer
                print(f"Warning: Skipping line #{line_num} (column {i+1} '{parts[i]}' is not an integer): {line.strip()}", file=sys.stderr)
                continue

            # If all checks passed, the line is considered valid.
            valid_lines.append(line)
        # --- End of validation ---

        # Sort only the valid lines by the second column (index 1)
        sorted_lines = sorted(valid_lines, key=lambda line: int(line.split()[1]), reverse=True)

        for line in sorted_lines:
            sys.stdout.write(line)

    except FileNotFoundError:
        print(f"Error: The file '{args.input_file}' was not found.", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()