#!/bin/bash

# The script runs all built configurations of SQLite-test (threadtest3)
# by calling run_sqlite_test.sh. It determines configurations from build/test-* directories,
# where the built binaries are expected to be located.

# Usage example:
#   ./run_sqlite_tests_all.sh
#   ./run_sqlite_tests_all.sh vtune   # Will run all with VTune profiling

USE_VTUNE=false
if [[ "$1" == "vtune" ]]; then
  USE_VTUNE=true
  echo "VTune profiling is ENABLED for all runs."
fi

echo "Scanning for built configurations in 'build/test-*' ..."
echo ""

# Iterate through all build/test-* subdirectories
for d in build/test-*; do
    # Check if it's a directory
    if [ -d "$d" ]; then
        
        # Extract configuration name from folder name (e.g., test-tsan-lo -> tsan-lo)
        dir_name=$(basename "$d")    # test-tsan-lo
        config_name="${dir_name#test-}"  # tsan-lo
        
        # Check for executable file (threadtest3)
        exe_path="$d/threadtest3"
        if [ -x "$exe_path" ]; then
            # If vtune flag is passed - run with second argument
            if [ "$USE_VTUNE" = true ]; then
                echo "-----------------------------------------"
                echo "Running configuration: $config_name (with VTune)"
                ./run_sqlite_test.sh "$config_name" vtune
            else
                echo "-----------------------------------------"
                echo "Running configuration: $config_name"
                ./run_sqlite_test.sh "$config_name"
            fi
        else
            echo "Skipping '$config_name' — no executable '$exe_path' found."
        fi
    fi
done

echo ""
echo "All detected configurations have been processed."