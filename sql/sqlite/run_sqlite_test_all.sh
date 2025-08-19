#!/bin/bash

# This script finds all compiled test configurations in the 'build' directory
# and runs the benchmark for each one using './run_sqlite_test.sh'.

set -e

BUILD_DIR="build"
RUN_SCRIPT="./run_sqlite_test.sh"

# Argument parsing to separate 'contention' from other arguments to be forwarded
is_contention=false
forward_args=()
for arg in "$@"; do
    if [ "$arg" == "contention" ]; then
        is_contention=true
    else
        forward_args+=("$arg")
    fi
done

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

# Find all build directories, which are expected to be named 'test-<config_name>'
# The result of the find command is stored in an array to handle spaces or special characters.
mapfile -t build_dirs < <(find "$BUILD_DIR" -maxdepth 1 -type d -name 'test-*')

if [ ${#build_dirs[@]} -eq 0 ]; then
    echo "No compiled test configurations found in '$BUILD_DIR'."
    echo "Directories should be named like 'build/test-orig', 'build/test-tsan-dom', etc."
    exit 0
fi

echo "Found ${#build_dirs[@]} compiled configurations. Starting tests..."
echo "Any arguments passed to this script (like 'vtune' or 'trace') will be forwarded to the test runner."
echo ""

# --- Test Execution Loop ---
for build_path in "${build_dirs[@]}"; do
    # Extract the configuration name from the directory path 'build/test-my-config' -> 'my-config'
    config_name=$(basename "$build_path" | sed 's/^test-//')

    if [ -z "$config_name" ]; then
        echo "Warning: Could not extract a valid configuration name from '$build_path'. Skipping."
        continue
    fi

    if [ "$is_contention" = true ]; then
        echo "-- Contention mode --"
        # Contention mode - run with varying thread counts
        min_threads=2
        max_threads=$(nproc)
        for threads in $(seq "$min_threads" 2 "$max_threads"); do
            echo "Number of threads: $threads"
            if ! "$RUN_SCRIPT" "$config_name" "$threads" "${forward_args[@]}"; then
                echo "An error occurred while running the test for '$config_name' with $threads threads. Aborting."
                exit 1
            fi
        done
    else
        # Normal mode - run with default configuration
        echo "-- Normal mode --"
        if ! "$RUN_SCRIPT" "$config_name" "${forward_args[@]}"; then
            echo "An error occurred while running the test for '$config_name'. Aborting."
            exit 1
        fi
    fi
done

echo "----------------------------------------"
echo "All tests have been executed."
echo "You can now analyze the results in the 'results/' directory (e.g., using 'analyze_results.sh')."