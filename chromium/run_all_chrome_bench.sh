#!/bin/sh

# Directory to store the results
OUTPUT_DIR="results"

# List of tests to run
TESTS="speedometer3 blink_perf.svg blink_perf.layout blink_perf.dom blink_perf.parser"

# List of Chrome builds to test
BUILDS="chrome-orig chrome-tsan chrome-tsan-all chrome-tsan-dom chrome-tsan-ea chrome-tsan-lo chrome-tsan-stc chrome-tsan-swmr"

# Loop over each test
for TEST in $TESTS
do
  # Create a subdirectory for the current test's results
  TEST_OUTPUT_DIR="$OUTPUT_DIR/$TEST"

  # Loop over each build configuration
  for BUILD in $BUILDS
  do
    echo "Running test '$TEST' with build '$BUILD'"

    EXECUTABLE="out/$BUILD/chrome"
    MEMORY_LOG="$TEST_OUTPUT_DIR/memory_$BUILD.log"

    # Common arguments for run_benchmark
    BENCH_ARGS="$TEST \
      --browser=exact \
      --browser-executable=$EXECUTABLE \
      --output-dir=$TEST_OUTPUT_DIR \
      --results-label=$BUILD"

    # Command to measure peak memory usage
    # The result (in kilobytes) will be saved to $MEMORY_LOG
    TIME_CMD="/usr/bin/time -o $MEMORY_LOG -f %M"

    if [ "$BUILD" = "chrome-orig" ]; then
      # Run for the native build
      $TIME_CMD tools/perf/run_benchmark $BENCH_ARGS
    else
      # Run for TSan builds with extra options
      TSAN_OPTIONS="atexit_sleep_ms=200 flush_memory_ms=2000" \
      $TIME_CMD tools/perf/run_benchmark $BENCH_ARGS \
        --extra-browser-args="--no-sandbox --disable-gpu"
    fi

    echo "Test '$TEST' with build '$BUILD' finished. Peak memory usage (KB) saved to $MEMORY_LOG"
    echo "--------------------------------------------------"
  done
done

echo "All tests are complete."