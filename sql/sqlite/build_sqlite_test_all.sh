#!/bin/bash

set -e

# Source the configuration definitions
source ../../config_definitions.sh || exit $?

# Check if the CONFIG_DETAILS array was loaded
if [ ${#CONFIG_DETAILS[@]} -eq 0 ]; then
    echo "Error: Failed to load configuration definitions from config_definitions_sqlite.sh"
    exit 1
fi

# Create directory for results
results_dir="results"
mkdir -p "$results_dir"
compilation_log_file="$results_dir/compilation_times.log"
stats_log_file="$results_dir/instr_count.log"


# Clear previous log files
> "$compilation_log_file"
> "$stats_log_file"

echo "Starting build for all test configurations..."

# Iterate over all keys (configuration names) in CONFIG_DETAILS
for config_name in "${!CONFIG_DETAILS[@]}" "tsan-dom-ea-lo-st-swmr"; do
    echo "----------------------------------------"
    echo "Building configuration: $config_name"

    # 1. Rename existing __tsan__ directory to avoid conflicts
    if [ -d "/tmp/__tsan__" ]; then
        dest="/tmp/__tsan__old"
        i=1
        while [ -d "$dest" ]; do
            dest="/tmp/__tsan__old_$i"
            i=$((i+1))
        done
        echo "Backing up existing '/tmp/__tsan__' to '$dest'"
        mv /tmp/__tsan__ "$dest"
    fi

    # Measure compilation time
    start_time=$(date +%s)
    if ! bash ./build_sqlite_test.sh "$config_name"; then
        echo "Error building configuration: $config_name"
        exit 1
    fi
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    echo "Configuration '$config_name' compiled in $duration seconds."
    echo "$config_name: $duration" >> "$compilation_log_file"

    # 2. Summarize instruction statistics and log the count
    if [ -d "/tmp/__tsan__" ]; then
        instr_count=$(summarize_instr_stats.py)
        echo "Instrumented instructions for '$config_name': $instr_count"
        echo "$config_name: $instr_count" >> "$stats_log_file"
    else
        echo "Warning: Directory '/tmp/__tsan__' not found after build. Cannot count instrumented instructions."
        echo "$config_name: N/A" >> "$stats_log_file"
    fi

    rm -f *.db *.db-wal
done

# All optimizations
config_name="tsan-dom-ea-lo-st-swmr"
echo "----------------------------------------"
echo "Building configuration: $config_name"

# 1. Rename existing __tsan__ directory
if [ -d "/tmp/__tsan__" ]; then
    dest="/tmp/__tsan__old"
    i=1
    while [ -d "$dest" ]; do
        dest="/tmp/__tsan__old_$i"
        i=$((i+1))
    done
    echo "Backing up existing '/tmp/__tsan__' to '$dest'"
    mv /tmp/__tsan__ "$dest"
fi

# Measure compilation time
start_time=$(date +%s)
if ! bash ./build_sqlite_test.sh "$config_name"; then
    echo "Error building configuration: $config_name"
    exit 1
fi
end_time=$(date +%s)
duration=$((end_time - start_time))
echo "Configuration '$config_name' compiled in $duration seconds."
echo "$config_name: $duration" >> "$compilation_log_file"

# 2. Summarize instruction statistics and log the count
if [ -d "/tmp/__tsan__" ]; then
    instr_count=$(python3 ../../summarize_instr_stats.py)
    echo "Instrumented instructions for '$config_name': $instr_count"
    echo "$config_name: $instr_count" >> "$stats_log_file"
else
    echo "Warning: Directory '/tmp/__tsan__' not found after build. Cannot count instrumented instructions."
    echo "$config_name: N/A" >> "$stats_log_file"
fi


rm -f *.db *.db-wal

echo "----------------------------------------"
echo "Building all configurations completed."
echo "Compilation times logged to $compilation_log_file"
echo "Instruction counts logged to $stats_log_file"