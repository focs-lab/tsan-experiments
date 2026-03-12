#!/bin/bash
set -Eeuo pipefail

# Directory to store the results. May be overridden via OUTPUT_DIR=/path/to/results.
OUTPUT_DIR="${OUTPUT_DIR:-results}"

# List of tests to run
TESTS=(
  speedometer3
  blink_perf.svg
  blink_perf.layout
  blink_perf.dom
  blink_perf.parser
)

# List of Chrome builds to test
#BUILDS=(chrome-orig chrome-tsan chrome-tsan-all chrome-tsan-dom chrome-tsan-ea chrome-tsan-lo chrome-tsan-stc chrome-tsan-swmr)
BUILDS=(chrome-tsan chrome-tsan-all chrome-tsan-all-no-peeling)

BENCHMARK_RUNNER="tools/perf/run_benchmark"
TIME_BIN="/usr/bin/time"
TSAN_EXTRA_OPTIONS="atexit_sleep_ms=200 flush_memory_ms=2000 report_bugs=0"

require_command() {
  if ! command -v "$1" > /dev/null 2>&1; then
    echo "Error: required command '$1' was not found in PATH." >&2
    exit 1
  fi
}

require_path() {
  local path="$1"
  local description="$2"
  if [ ! -e "$path" ]; then
    echo "Error: $description not found at '$path'." >&2
    exit 1
  fi
}

if [ ! -e "$BENCHMARK_RUNNER" ]; then
  echo "Error: '$BENCHMARK_RUNNER' was not found. Run this script from the Chromium src directory." >&2
  exit 1
fi

if [ ! -x "$TIME_BIN" ]; then
  echo "Error: '$TIME_BIN' is not available or not executable." >&2
  exit 1
fi

RUNNER=()
if [ -z "${DISPLAY:-}" ]; then
  require_command xvfb-run
  RUNNER=(xvfb-run -a)
fi

# Loop over each test
for TEST in "${TESTS[@]}"; do
  # Create a subdirectory for the current test's results
  TEST_OUTPUT_DIR="$OUTPUT_DIR/$TEST"
  mkdir -p "$TEST_OUTPUT_DIR"

  # Loop over each build configuration
  for BUILD in "${BUILDS[@]}"; do
    echo "Running test '$TEST' with build '$BUILD'"

    EXECUTABLE="out/$BUILD/chrome"
    RUN_OUTPUT_DIR="$TEST_OUTPUT_DIR/$BUILD"
    MEMORY_LOG="$TEST_OUTPUT_DIR/memory_$BUILD.log"
    RUN_LOG="$TEST_OUTPUT_DIR/run_$BUILD.log"
    mkdir -p "$RUN_OUTPUT_DIR"

    require_path "$EXECUTABLE" "Chrome executable for build '$BUILD'"

    BENCHMARK_CMD=(
      "$BENCHMARK_RUNNER" "$TEST"
      --browser=exact
      --browser-executable="$EXECUTABLE"
      --output-dir="$RUN_OUTPUT_DIR"
      --results-label="$BUILD"
      --extra-browser-args="--no-sandbox --disable-gpu"
    )

    if [ "$BUILD" = "chrome-orig" ]; then
      "${RUNNER[@]}" "$TIME_BIN" -o "$MEMORY_LOG" -f %M \
        "${BENCHMARK_CMD[@]}" > "$RUN_LOG" 2>&1
    else
      (
        if [ -n "${TSAN_OPTIONS:-}" ]; then
          export TSAN_OPTIONS="${TSAN_OPTIONS} ${TSAN_EXTRA_OPTIONS}"
        else
          export TSAN_OPTIONS="$TSAN_EXTRA_OPTIONS"
        fi

        "${RUNNER[@]}" "$TIME_BIN" -o "$MEMORY_LOG" -f %M \
          "${BENCHMARK_CMD[@]}"
      ) > "$RUN_LOG" 2>&1
    fi

    echo "Test '$TEST' with build '$BUILD' finished."
    echo "  Results: $RUN_OUTPUT_DIR"
    echo "  Peak memory (KB): $MEMORY_LOG"
    echo "  Full log: $RUN_LOG"
    echo "--------------------------------------------------"
  done
done

echo "All tests are complete. Results are under '$OUTPUT_DIR'."
