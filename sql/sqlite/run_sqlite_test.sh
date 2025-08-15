#!/bin/bash

# --- Argument Parsing ---
if [ -z "$1" ]; then
  echo "Usage: $0 <config_type> [nthreads] [vtune]"
  echo "Description: Runs the threadtest3 benchmark for a given build configuration."
  echo ""
  echo "Arguments:"
  echo "  <config_type>: The name of the configuration to run (e.g., 'orig', 'tsan-lo')."
  echo "                 This corresponds to a build directory at 'build/test-<config_type>'."
  echo "  [nthreads]:    (Optional) Number of threads for walthread1 and walthread3 tests."
  echo "  [vtune]:       (Optional) If specified, runs the test with Intel VTune profiling."
  echo ""
  echo "Example:"
  echo "  ./run_sqlite_test.sh tsan-lo"
  echo "  ./run_sqlite_test.sh tsan-lo 4"
  echo "  ./run_sqlite_test.sh tsan-lo vtune"
  exit 1
fi

CONFIG_TYPE=$1
BUILD_DIR="build/test-$CONFIG_TYPE"
EXECUTABLE_PATH="$BUILD_DIR/threadtest3"

# --- Result and Output Setup ---
RESULTS_DIR="results"
VTUNE_RESULTS_ROOT="vtune_results"
mkdir -p "$RESULTS_DIR"

# --- Executable Validation ---
if [ ! -x "$EXECUTABLE_PATH" ]; then
  echo "Error: Test executable not found or not executable at '$EXECUTABLE_PATH'."
  echo "Please ensure you have built this configuration first by running:"
  echo "  ./build_sqlite_test.sh $CONFIG_TYPE"
  exit 1
fi

# Determine if VTune should be used
USE_VTUNE=false
if [[ "$2" == "vtune" ]] || [[ "$3" == "vtune" ]]; then
    USE_VTUNE=true
    mkdir -p "$VTUNE_RESULTS_ROOT"
fi

# --- Test Execution ---
echo "--- Running Benchmark for: $CONFIG_TYPE ---"

# Set TSAN_OPTIONS to get a summary report instead of stopping at the first data race.
# This ensures the benchmark runs to completion.
export TSAN_OPTIONS="report_bugs=0"

# Base command to execute the test
CMD="$EXECUTABLE_PATH"

# Check if second argument is a number (thread count)
if [[ $2 =~ ^[0-9]+$ ]]; then
    NTHREADS=$2
#    CMD="$CMD --w1-threads $NTHREADS --w3-threads $NTHREADS walthread1 walthread3"
    CMD="$CMD --w1-threads $NTHREADS walthread1"
    RESULTS_DIR=${RESULTS_DIR}/contention
    mkdir -p "$RESULTS_DIR"
    RESULT_FILE="$RESULTS_DIR/${CONFIG_TYPE}_${NTHREADS}threads.log"
else
    RESULT_FILE="$RESULTS_DIR/${CONFIG_TYPE}.log"
fi

# If VTune is enabled, wrap the command
if [ "$USE_VTUNE" = true ]; then
    VTUNE_ANALYSIS_TYPE="hotspots" # Common analysis types: hotspots, threading, memory-consumption
    VTUNE_RESULT_DIR="$VTUNE_RESULTS_ROOT/sqlite_${CONFIG_TYPE}_$(date +%Y-%m-%d_%H-%M)"
    VTUNE_OPTIONS="--collect=$VTUNE_ANALYSIS_TYPE --result-dir=$VTUNE_RESULT_DIR -knob sampling-mode=hw"

    echo "VTune Profiling: ENABLED"
    echo "VTune Analysis Type: $VTUNE_ANALYSIS_TYPE"
    echo "VTune results will be stored in: $VTUNE_RESULT_DIR"

    # Prepend the vtune command and its options
    CMD="vtune $VTUNE_OPTIONS -- $CMD"
fi

echo "Executable: $EXECUTABLE_PATH"
echo "Full Command: $CMD"
echo "Output will be saved to: $RESULT_FILE"
echo "Running, please wait..."

# Execute the command, redirecting both stdout and stderr to the result file.
# Using 'eval' to ensure the command string with its arguments and potential quotes is parsed correctly by the shell.
eval $CMD &> "$RESULT_FILE"

# Check the exit code of the executed command
if [ $? -eq 0 ]; then
    echo "--- Benchmark for [$CONFIG_TYPE] completed successfully. ---"
else
    # The TSan runtime exits with a non-zero code if races are found. This is expected.
    if [[ "$CONFIG_TYPE" == tsan* ]]; then
        echo "--- Benchmark for TSan configuration [$CONFIG_TYPE] completed. ---"
        echo "NOTE: A non-zero exit code is expected for TSan when data races are detected."
    else
        echo "--- Benchmark for [$CONFIG_TYPE] FAILED with a non-zero exit code. ---"
    fi
    echo "Please check the log file for details: $RESULT_FILE"
fi

echo ""