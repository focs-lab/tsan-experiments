#!/usr/bin/env python3
import sys
import argparse

def main():
    """
    Main function to parse arguments and sort the log file.
    """
    # --- Argument Parsing ---
    # Sets up a command-line interface to get the input file name.
    parser = argparse.ArgumentParser(
        description="Sorts a log file numerically by its second column in descending order.",
        epilog="Example: python3 sort_log.py my_app.log > sorted.log"
    )
    parser.add_argument(
        "input_file",
        help="The path to the log file to be sorted."
    )
    args = parser.parse_args()

    # --- File Processing ---
    try:
        # Open and read all lines from the specified file
        with open(args.input_file, 'r') as f:
            lines = f.readlines()

        # Sort the lines.
        # The key for sorting is a lambda function that:
        # 1. Splits the line into a list of words.
        # 2. Takes the second element (at index 1).
        # 3. Converts it to an integer for correct numerical comparison.
        # The sort is done in descending order (reverse=True).
        sorted_lines = sorted(lines, key=lambda line: int(line.split()[1]), reverse=True)

        # Write the sorted lines to standard output
        for line in sorted_lines:
            sys.stdout.write(line)

    except FileNotFoundError:
        # If the file doesn't exist, print an error to standard error and exit.
        print(f"Error: The file '{args.input_file}' was not found.", file=sys.stderr)
        sys.exit(1)
    except (ValueError, IndexError) as e:
        # If a line has an incorrect format (e.g., not enough columns or the
        # second column is not a number), print an error and exit.
        print(f"Error: A line in '{args.input_file}' has an invalid format.", file=sys.stderr)
        print(f"Details: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()