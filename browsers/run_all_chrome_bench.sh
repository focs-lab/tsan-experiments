#!/bin/sh

OUTPUT_DIR="results"

for TEST in "speedometer3" "speedometer2" "blink_perf.svg" \
    "blink_perf.layout" "blink_perf.dom" "blink_perf.parser"
#    "blink_perf.image_decoder" "blink_perf.paint" # give a lot of missing
do
  tools/perf/run_benchmark "$TEST" \
      --browser=exact \
      --browser-executable="out/chrome-orig/chrome" \
      --output-dir="$OUTPUT_DIR/$TEST" \
      --results-label="orig"

  TSAN_OPTIONS="atexit_sleep_ms=200 flush_memory_ms=2000" \
  tools/perf/run_benchmark "$TEST" \
      --browser=exact \
      --browser-executable="out/chrome-tsan/chrome" \
      --extra-browser-args="--no-sandbox --disable-gpu" \
      --output-dir="$OUTPUT_DIR/$TEST" \
      --results-label="tsan"

 TSAN_OPTIONS="atexit_sleep_ms=200 flush_memory_ms=2000" \
    tools/perf/run_benchmark "$TEST" \
        --browser=exact \
        --browser-executable="out/chrome-tsan-all/chrome" \
        --extra-browser-args="--no-sandbox --disable-gpu" \
        --output-dir="$OUTPUT_DIR/$TEST" \
        --results-label="tsan-opt"
done