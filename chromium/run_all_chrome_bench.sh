#!/bin/bash
# run_all_chrome_bench.sh — Telemetry benchmarks for the P5 re-measurement, N repetitions, CSV output.
# Run from the Chromium src dir (or set SRC_DIR). Rep-outer / build-inner order spreads drift over builds.
#   env: HASH (compiler stamp, results root /extra/alexey/chromium/results-<HASH>), REPS (default 3),
#        BUILDS ("tsan tsan-sound ..." = out/chrome-<cfg> names), TESTS (suites), CPUSET (taskset, default 28-43,84-99),
#        TSAN_EXTRA_OPTIONS, OUTPUT_DIR (override root)
set -Eeuo pipefail
SRC=${SRC_DIR:-/extra/alexey/chromium/chromium/src}; cd "$SRC"
# tools/perf/run_benchmark is "#!/usr/bin/env vpython3": depot_tools must be on PATH (build_configs.sh sets it
# too; a launch from a clean nohup environment failed every run with rc=127 on 2026-09-05).
export PATH=/extra/alexey/chromium/depot_tools:$PATH
command -v vpython3 >/dev/null || { echo "vpython3 not found (depot_tools)" >&2; exit 1; }
HASH=${HASH:?compiler hash (results root suffix)}; REPS=${REPS:-3}
OUTPUT_DIR="${OUTPUT_DIR:-/extra/alexey/chromium/results-$HASH}"
TESTS=(${TESTS:-speedometer3 blink_perf.svg blink_perf.layout blink_perf.dom blink_perf.parser blink_perf.paint blink_perf.image_decoder})
BUILDS=(${BUILDS:-tsan tsan-sound tsan-dom-ea-lo-st-swmr})
# 48 CPUs, the same set every other application is measured on. 16 CPUs (28-43,84-99) made a TSan Chromium
# miss Telemetry's default 60 s browser-startup timeout on every story (2026-09-05); March ran unpinned on 112.
CPUSET=${CPUSET:-4-27,60-83}
# Telemetry's browser-startup timeout (60 s) has no CLI flag: it is raised to 600 s in the checkout's
# telemetry/internal/browser/browser_options.py (copy in files_with_fixed_timeout/).
BENCHMARK_RUNNER="tools/perf/run_benchmark"
TSAN_EXTRA_OPTIONS="${TSAN_EXTRA_OPTIONS:-atexit_sleep_ms=200 flush_memory_ms=2000 report_bugs=0}"
[ -e "$BENCHMARK_RUNNER" ] || { echo "run from the Chromium src dir" >&2; exit 1; }
# Always run under a private Xvfb. An inherited DISPLAY (an SSH-forwarded localhost:N from the launching shell)
# is not usable by a detached run: chrome never came up, Telemetry waited the full startup timeout per story
# and every story "failed" (2026-09-05). Unset it and never trust it.
unset DISPLAY; command -v xvfb-run >/dev/null || { echo "xvfb-run missing" >&2; exit 1; }; RUNNER=(xvfb-run -a)
mkdir -p "$OUTPUT_DIR"; LOG="$OUTPUT_DIR/runs.jsonl"
for B in "${BUILDS[@]}"; do [ -x "out/chrome-$B/chrome" ] || { echo "missing out/chrome-$B/chrome" >&2; exit 1; }
  mkdir -p "$OUTPUT_DIR/build_info"; cp "out/chrome-$B/build_info.txt" "$OUTPUT_DIR/build_info/chrome-$B.txt" 2>/dev/null || true; done
for ((rep=1; rep<=REPS; rep++)); do
  for TEST in "${TESTS[@]}"; do
    for B in "${BUILDS[@]}"; do
      RUN_DIR="$OUTPUT_DIR/$TEST/rep$rep"; mkdir -p "$RUN_DIR"
      # done = a results.csv with rows exists for this (test, build, rep): a suite in which one story exceeded
      # Telemetry's per-story cap returns rc=1 but its other stories are measured and valid (SierpinskiCarpet
      # under TSan, 2026-09-05); re-running the whole 40-minute suite for a story that will time out again is waste.
      if [ -s "$RUN_DIR/results.csv" ] && [ "$(grep -c "chrome-$B" "$RUN_DIR/results.csv")" -gt 1 ]; then echo "skip $TEST $B rep$rep (results present)"; continue; fi
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
