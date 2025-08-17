#!/bin/bash

# This script finds all compiled test configurations in the 'build' directory
# and runs the benchmark for each one using './run_sqlite_test.sh'.

set -e

BUILD_DIR="build"
RUN_SCRIPT="./run_sqlite_test.sh"
TRACES_DIR="traces"

# --- Argument Parsing ---
TRACE_MODE=false
ARGS_TO_FORWARD=()
for arg in "$@"; do
    if [[ "$arg" == "trace" ]]; then
        TRACE_MODE=true
    else
        ARGS_TO_FORWARD+=("$arg")
    fi
done

# --- Trace Mode Setup ---
if [ "$TRACE_MODE" = true ]; then
    if ! command -v zstd > /dev/null 2>&1; then
        echo "Error: 'zstd' is not found, but is required for trace mode." >&2
        exit 1
    fi
    mkdir -p "$TRACES_DIR"
    echo "Trace mode enabled. Compressed traces will be saved to '$TRACES_DIR/'."
fi

# Function to check if running in contention mode
check_contention_mode() {
    for arg in "$@"; do
        if [[ "$arg" == "contention" ]]; then
            return 0 # 0 for true in bash
        fi
    done
    return 1 # 1 for false
}

# --- Pre-run Checks ---
if [ ! -d "$BUILD_DIR" ]; then
    echo "Error: Build directory '$BUILD_DIR' not found."
    echo "Please build the test configurations first (e.g., using 'build_sqlite_test_all.sh')."
    exit 1
fi

if [ ! -x "$RUN_SCRIPT" ]; then
    echo "Error: Run script '$RUN_SCRIPT' not found or not executable."
    exit 1
fi

# Find all build directories
mapfile -t build_dirs < <(find "$BUILD_DIR" -maxdepth 1 -type d -name 'test-*')

if [ ${#build_dirs[@]} -eq 0 ]; then
    echo "No compiled test configurations found in '$BUILD_DIR'."
    echo "Directories should be named like 'build/test-orig', 'build/test-tsan-dom', etc."
    exit 0
fi

echo "Found ${#build_dirs[@]} compiled configurations. Starting tests..."
echo "Any arguments passed to this script will be forwarded to the test runner."
echo ""

# --- Test Execution Loop ---
for build_path in "${build_dirs[@]}"; do
    config_name=$(basename "$build_path" | sed 's/^test-//')

    if [ -z "$config_name" ]; then
        echo "Warning: Could not extract a valid configuration name from '$build_path'. Skipping."
        continue
    fi

    if check_contention_mode "${ARGS_TO_FORWARD[@]}"; then
        echo "-- Contention mode for '$config_name' --"
        min_threads=2
        max_threads=$(nproc)
        for threads in $(seq "$min_threads" 2 "$max_threads"); do
            echo "  Number of threads: $threads"
                if ! "$RUN_SCRIPT" "$config_name" "$threads"; then
                    echo "An error occurred while running the test for '$config_name' with $threads threads. Aborting."
                    exit 1
                fi
            fi
        done
    else
        echo "-- Normal mode for '$config_name' --"
        if [ "$TRACE_MODE" = true ]; then
            TRACE_FILE_ZST="$TRACES_DIR/sqlite_test_${config_name}.log.zst"
            # Using eval to correctly handle arguments and the pipeline
            CMD="bash -c \"set -o pipefail; \\\"$RUN_SCRIPT\\\" \\\"$config_name\\\" \\\"${ARGS_TO_FORWARD[@]}\\\" 2>&1 | zstd -1 -o '$TRACE_FILE_ZST'\""
            if ! eval "$CMD"; then
                echo "An error occurred while running the traced test for '$config_name'. Aborting."
                exit 1
            fi
        else
            if ! "$RUN_SCRIPT" "$config_name" "${ARGS_TO_FORWARD[@]}"; then
                echo "An error occurred while running the test for '$config_name'. Aborting."
                exit 1
            fi
        fi
    fi
    echo "" # Add a newline for better separation
done

echo "----------------------------------------"
echo "All tests have been executed."
if [ "$TRACE_MODE" = true ]; then
    echo "Compressed traces are located in the '$TRACES_DIR/' directory."
fi
echo "You can now analyze the results in the 'results/' directory (e.g., using 'analyze_results.sh')."