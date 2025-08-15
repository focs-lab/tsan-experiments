#!/bin/bash

# This script automates running benchmarks for all memcached configurations
# defined in config_definitions.sh.

set -e

# --- Variables ---
RUN_MEMCACHED_SCRIPT="./run-memcached.sh"
RUN_BENCH_SCRIPT="./run-bench.sh"
CONFIG_DEFINITIONS="./config_definitions.sh"
TRACES_DIR="traces"
TRACE_MODE=false

# --- Argument Parsing for Trace Mode ---
for arg in "$@"; do
    if [ "$arg" = "trace" ]; then
        TRACE_MODE=true
        break
    fi
done

if [ "$TRACE_MODE" = true ]; then
    echo "Trace mode enabled. Traces will be saved to '$TRACES_DIR/'."
    mkdir -p "$TRACES_DIR"
fi

# --- Pre-run Checks ---
if [ ! -f "$CONFIG_DEFINITIONS" ]; then
    echo "Error: Configuration definitions file '$CONFIG_DEFINITIONS' not found."
    exit 1
fi

if [ ! -x "$RUN_MEMCACHED_SCRIPT" ]; then
    echo "Error: Memcached run script '$RUN_MEMCACHED_SCRIPT' not found or not executable."
    exit 1
fi

if [ ! -x "$RUN_BENCH_SCRIPT" ]; then
    echo "Error: Benchmark run script '$RUN_BENCH_SCRIPT' not found or not executable."
    exit 1
fi

# 1. Source the configuration definitions
# shellcheck source=config_definitions.sh
source "$CONFIG_DEFINITIONS"

# Check if the configurations were loaded successfully
if [ ${#CONFIG_DETAILS[@]} -eq 0 ]; then
    echo "Error: Failed to load configuration definitions from '$CONFIG_DEFINITIONS'"
    exit 1
fi

echo "Starting benchmark runs for all memcached configurations..."
echo "Any arguments passed to this script (e.g., 'vtune', 'perf', or 'trace') will be forwarded to the run scripts."
echo ""

# --- Main Test Execution Loop ---
for config_name in "${!CONFIG_DETAILS[@]}"; do
    echo "----------------------------------------"
    echo "--- Running test for configuration: $config_name ---"
    echo "----------------------------------------"

    # 2. Run memcached with the current configuration
    # '$@' forwards all arguments from this script (e.g., 'vtune' or 'perf' or 'trace')
    if [ "$TRACE_MODE" = true ]; then
        TRACE_FILE="$TRACES_DIR/${config_name}.log"
        echo "Redirecting trace output to $TRACE_FILE"
        if ! "$RUN_MEMCACHED_SCRIPT" "$config_name" "$@" > "$TRACE_FILE" 2>&1; then
            echo "Error running memcached for configuration: $config_name. Aborting."
            exit 1
        fi
    else
        if ! "$RUN_MEMCACHED_SCRIPT" "$config_name" "$@"; then
            echo "Error running memcached for configuration: $config_name. Aborting."
            exit 1
        fi
    fi

    # Give memcached some time to fully initialize before starting the benchmark.
    # run-memcached.sh already has a delay, but a small extra pause won't hurt.
    sleep 2

    # 3. Run the benchmark, passing 'trace' if in trace mode
    BENCH_ARGS=""
    if [ "$TRACE_MODE" = true ]; then
        BENCH_ARGS="trace"
    fi
    
    if ! "$RUN_BENCH_SCRIPT" $BENCH_ARGS; then
        echo "Error running the benchmark for configuration: $config_name. Aborting."
        # The memcached process is stopped by the run-bench.sh script, so no extra cleanup is needed here.
        exit 1
    fi

    echo "--- Test for configuration $config_name finished ---"

    # Short pause before the next run for system stability
    sleep 2
done

echo "========================================"
echo "All tests have been completed."
echo "Results are located in the 'results/' directory."
if [ "$TRACE_MODE" = true ]; then
    echo "Traces are located in the '$TRACES_DIR/' directory."
fi