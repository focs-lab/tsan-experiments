#!/bin/bash
# chromium_bench_after.sh <hash> — Stage A Chromium benchmarks, started as soon as the two builds are complete.
# Takes the same exclusive lock the application runs use, so a MySQL run and a Chromium suite never overlap
# (the interference pilot rejected running two benchmarks at once).  The cheaper suite runs first so the
# Chromium half of the pipeline is validated early instead of after hours of speedometer3.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh
HASH=${1:?}; REPS=${REPS:-2}; SRC=/extra/alexey/chromium/chromium/src
BUILDS=${BUILDS:-"tsan tsan-sound"}; TESTS=${TESTS:-"blink_perf.svg speedometer3"}
OUT="$P5_DIR/results/$(date +%F)-$HASH"
for b in $BUILDS; do
  p5_log "waiting for the Chromium $b build"
  until [ -f "$SRC/out/chrome-$b/build_info.txt" ] && grep -q "compiler_head: $HASH" "$SRC/out/chrome-$b/build_info.txt" 2>/dev/null; do sleep 300; done
done
p5_log "both Chromium builds present; taking the benchmark lock"
exec 9>"$P5_LOCK"; flock -x 9
p5_log "Chromium Stage A benchmarks: builds='$BUILDS' tests='$TESTS' reps=$REPS"
( cd "$SRC" && HASH="$HASH" REPS="$REPS" BUILDS="$BUILDS" TESTS="$TESTS" \
    /home/alexey/tsan-experiments/chromium/run_all_chrome_bench.sh ) > "$OUT/chromium-bench.log" 2>&1
rc=$?
p5_log "Chromium benchmarks finished rc=$rc"
python3 ../chrome-result-processing/aggregate_reps.py "/extra/alexey/chromium/results-$HASH" > "$OUT/chromium-aggregate.log" 2>&1 || true
echo "STAGE-A-CHROMIUM DONE $(date -Iseconds) rc=$rc" >> "$OUT/pipeline.log"
