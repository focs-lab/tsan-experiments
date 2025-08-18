#!/bin/bash

# --- Script Logic ---

# 1. Input Validation
if [ -z "$1" ]; then
  echo "Usage: $0 <directory_with_traces>" >&2
  exit 1
fi

# Check if zstd is installed
if ! command -v zstdcat &> /dev/null; then
    echo "Error: 'zstd' command-line utility is not installed." >&2
    echo "Please install it (e.g., 'sudo apt-get install zstd' or 'brew install zstd')." >&2
    exit 1
fi

TRACE_DIR=$1
# Directory to store analysis results, inside the trace directory
RESULTS_DIR="$TRACE_DIR/results"
ANALYSIS_SCRIPT=""

# 2. Locate the analysis script
# First, check if 'trace-analyze.py' is in the PATH
if command -v trace-analyze.py &> /dev/null; then
    ANALYSIS_SCRIPT="trace-analyze.py"
# If not in PATH, check if it's in the same directory as this script
else
    SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    POTENTIAL_SCRIPT_PATH="$SCRIPT_DIR/trace-analyze.py"
    if [ -f "$POTENTIAL_SCRIPT_PATH" ]; then
        ANALYSIS_SCRIPT="$POTENTIAL_SCRIPT_PATH"
    fi
fi

# If the analysis script was not found in either location, exit
if [ -z "$ANALYSIS_SCRIPT" ]; then
    echo "Error: 'trace-analyze.py' could not be found." >&2
    echo "Please ensure the script is in your system's PATH or in the same directory as 'analyze_traces.sh'." >&2
    exit 1
fi

# 3. Create results directory
mkdir -p "$RESULTS_DIR"

# 4. Find and process files
echo "Searching for .zst traces in '$TRACE_DIR' directory..."

# Use 'find' to safely handle filenames with spaces and other special characters
find "$TRACE_DIR" -maxdepth 1 -type f -name '*.zst' -print0 | while IFS= read -r -d '' zst_file; do

  # Get the base name of the file without the .zst extension
  base_name=$(basename "$zst_file" .zst)
  # Construct the output filename
  output_file="$RESULTS_DIR/${base_name}.log"

  echo " - Processing '$zst_file'..."

  # Decompress the file and pipe it to the analysis script via process substitution <().
  # Standard output (stdout) from the python script is redirected to the log file.
  # Error messages (stderr) will be displayed in the console.
  python3 "$ANALYSIS_SCRIPT" <(zstdcat "$zst_file") > "$output_file"

  # Check the exit code of the last command
  if [ $? -eq 0 ]; then
    echo "   -> Result saved to '$output_file'"
  else
    echo "   -> Error processing '$zst_file'. The file '$output_file' may contain error details."
  fi
done

echo
echo "Analysis complete. All results are in the '$RESULTS_DIR' directory."