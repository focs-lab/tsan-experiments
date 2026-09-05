#!/bin/bash
# chromium_stock_first.sh — the sound Chromium build is blocked behind a single ~hour-long compile (EA on
# vk_safe_struct_utils.cpp); its ninja is SIGSTOPped so it cannot resume 40-way mid-measurement. Run the
# Stage A suites on the stock build now (both suites, 2 reps), under the benchmark lock; the later full run
# skips entries already in runs.jsonl with rc 0. Afterwards resume ninja.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh
HASH=729521af8965; OUT="$P5_DIR/results/2026-09-04-$HASH"; SRC=/extra/alexey/chromium/chromium/src
exec 9>"$P5_LOCK"; flock -x 9
p5_log "Chromium suites on the stock build only (tsan; blink_perf.svg speedometer3; reps=2)"
( cd "$SRC" && HASH="$HASH" REPS=2 BUILDS="tsan" TESTS="blink_perf.svg speedometer3" \
    /home/alexey/tsan-experiments/chromium/run_all_chrome_bench.sh ) > "$OUT/chromium-bench-stock.log" 2>&1; rc=$?
p5_log "stock-only suites finished rc=$rc; resuming the sound build's ninja"
kill -CONT 2228731 2>/dev/null
echo "STAGE-A-CHROMIUM-STOCK DONE $(date -Iseconds) rc=$rc" >> "$OUT/pipeline.log"
