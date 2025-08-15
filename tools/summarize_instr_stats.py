#!/usr/bin/env python3

import os
import sys

def summarize_tsan_logs():
    """
    Summarizes the instruction counts from all log files
    in the /tmp/__tsan__ directory.
    """
    log_dir = "/tmp/__tsan__"
    total_instructions = 0

    # 1. Check if the directory exists
    if not os.path.isdir(log_dir):
        print(f"Error: Directory '{log_dir}' not found.", file=sys.stderr)
        sys.exit(1)

    # print(f"Scanning files in {log_dir}...")

    # 2. Iterate over all files in the directory
    for filename in os.listdir(log_dir):
        file_path = os.path.join(log_dir, filename)

        # Make sure it's a file and not a subdirectory
        if os.path.isfile(file_path):
            try:
                # 3. Read the content and convert it to a number
                with open(file_path, 'r') as f:
                    content = f.read().strip()
                    if content:  # Check that the file is not empty
                        instruction_count = int(content)
                        total_instructions += instruction_count
                    else:
                        print(f"Warning: File '{filename}' is empty. Skipping.", file=sys.stderr)
            except ValueError:
                # Handle the error if the file does not contain a number
                print(f"Warning: Could not parse a number from file '{filename}'. Skipping.", file=sys.stderr)
            except IOError as e:
                # Handle file reading errors
                print(f"Warning: Could not read file '{filename}'. Error: {e}. Skipping.", file=sys.stderr)

    # 4. Print the final sum
    # print("\n" + "="*50)
    # print(f"Total number of instrumented instructions: {total_instructions}")
    # print("="*50)
    print(f"{total_instructions}")

if __name__ == "__main__":
    summarize_tsan_logs()