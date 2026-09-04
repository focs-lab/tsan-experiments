#!/bin/bash
# run_all_chrome_bench.sh — Telemetry benchmarks for the P5 re-measurement, N repetitions, CSV output.
# Run from the Chromium src dir (or set SRC_DIR). Rep-outer / build-inner order spreads drift over builds.
#   env: HASH (compiler stamp, results root /extra/alexey/chromium/results-<HASH>), REPS (default 3),
#        BUILDS ("tsan tsan-sound ..." = out/chrome-<cfg> names), TESTS (suites), CPUSET (taskset, default 28-43,84-99),
#        TSAN_EXTRA_OPTIONS, OUTPUT_DIR (override root)
set -Eeuo pipefail
SRC=${SRC_DIR:-/extra/alexey/chromium/chromium/src}; cd "$SRC"
HASH=${HASH:?compiler hash (results root suffix)}; REPS=${REPS:-3}
OUTPUT_DIR="${OUTPUT_DIR:-/extra/alexey/chromium/results-$HASH}"
TESTS=(${TESTS:-speedometer3 blink_perf.svg blink_perf.layout blink_perf.dom blink_perf.parser blink_perf.paint blink_perf.image_decoder})
BUILDS=(${BUILDS:-tsan tsan-sound tsan-dom-ea-lo-st-swmr})
CPUSET=${CPUSET:-28-43,84-99}
BENCHMARK_RUNNER="tools/perf/run_benchmark"
TSAN_EXTRA_OPTIONS="${TSAN_EXTRA_OPTIONS:-atexit_sleep_ms=200 flush_memory_ms=2000 report_bugs=0}"
[ -e "$BENCHMARK_RUNNER" ] || { echo "run from the Chromium src dir" >&2; exit 1; }
RUNNER=(); [ -n "${DISPLAY:-}" ] || { command -v xvfb-run >/dev/null || { echo "xvfb-run missing" >&2; exit 1; }; RUNNER=(xvfb-run -a); }
mkdir -p "$OUTPUT_DIR"; LOG="$OUTPUT_DIR/runs.jsonl"
for B in "${BUILDS[@]}"; do [ -x "out/chrome-$B/chrome" ] || { echo "missing out/chrome-$B/chrome" >&2; exit 1; }
  mkdir -p "$OUTPUT_DIR/build_info"; cp "out/chrome-$B/build_info.txt" "$OUTPUT_DIR/build_info/chrome-$B.txt" 2>/dev/null || true; done
for ((rep=1; rep<=REPS; rep++)); do
  for TEST in "${TESTS[@]}"; do
    for B in "${BUILDS[@]}"; do
      RUN_DIR="$OUTPUT_DIR/$TEST/rep$rep"; mkdir -p "$RUN_DIR"
      if grep -q "\"test\": \"$TEST\", \"build\": \"$B\", \"rep\": $rep, \"rc\": 0" "$LOG" 2>/dev/null; then echo "skip $TEST $B rep$rep (done)"; continue; fi
      echo "[$(date '+%F %T')] $TEST / chrome-$B / rep $rep"
      CMD=("$BENCHMARK_RUNNER" "$TEST" --browser=exact --browser-executable="out/chrome-$B/chrome"
           --output-dir="$RUN_DIR" --results-label="chrome-$B" --output-format=csv --output-format=html
           --extra-browser-args="--no-sandbox --disable-gpu")
      t0=$(date +%s); load0=$(cut -d' ' -f1 /proc/loadavg)
      if [ "$B" = orig ]; then unset TSAN_OPTIONS; else export TSAN_OPTIONS="${TSAN_OPTIONS:+$TSAN_OPTIONS }$TSAN_EXTRA_OPTIONS"; fi
      set +e; "${RUNNER[@]}" taskset -c "$CPUSET" "${CMD[@]}" > "$RUN_DIR/run_chrome-$B.log" 2>&1; rc=$?; set -e
      t1=$(date +%s)
      printf '{"test": "%s", "build": "%s", "rep": %d, "rc": %d, "seconds": %d, "start": %d, "cpuset": "%s", "loadavg_before": %s, "loadavg_after": %s, "tsan_options": "%s"}\n' \
        "$TEST" "$B" "$rep" "$rc" "$((t1-t0))" "$t0" "$CPUSET" "$load0" "$(cut -d' ' -f1 /proc/loadavg)" "${TSAN_OPTIONS:-}" >> "$LOG"
      echo "   rc=$rc in $((t1-t0))s -> $RUN_DIR"
    done
  done
done
echo "All done. Results under $OUTPUT_DIR (results.csv per <test>/rep<k>, one label per build)."
