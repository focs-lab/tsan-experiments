#!/bin/bash
# stageA_close.sh <hash> — the remaining Stage A work, in value order, each holding the benchmark lock:
#   1. FFmpeg run1 refill (four runs were lost to the probe overlap; run.sh skips the good ones),
#   2. the SQLite baseline probe — both configurations built with both compilers, measured in one window.
#      This is the one that decides whether the paper's 2.77x is reproducible at all, so it goes before the
#      memcached probe rather than after it,
#   3. the memcached placement probe (bimodality; the least load-bearing of the three).
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh
HASH=${1:?}; OUT="$P5_DIR/results/$(date +%F)-$HASH"
until grep -q "STAGE-A-FFMPEG-4T DONE" "$OUT/pipeline.log" 2>/dev/null; do sleep 120; done
p5_log "refilling the FFmpeg run1 gap left by the probe overlap"
FF_THREADS=4 ./run.sh ffmpeg "$HASH" 3 >> "$OUT/run-ffmpeg-4threads.log" 2>&1 || p5_log "ffmpeg refill exited non-zero"
p5_log "SQLite baseline probe (paper compiler vs final compiler, both configurations)"
./sqlite_baseline_probe.sh "$HASH" 2 > "$OUT/baseline.log" 2>&1
cp "$OUT-baseline/baseline.md" "$OUT/baseline.md" 2>/dev/null
echo "STAGE-A-BASELINE DONE $(date -Iseconds)" >> "$OUT/pipeline.log"
p5_log "memcached placement probe (holding the lock this time)"
./memcached_placement_probe.sh "$HASH" 5 > "$OUT/placement.log" 2>&1
cp "$OUT-placement/placement.md" "$OUT/placement.md" 2>/dev/null
python3 aggregate.py "$OUT" > /dev/null 2>&1
python3 write_readme_results.py "$OUT" > /dev/null 2>&1
echo "STAGE-A-RERUNS DONE $(date -Iseconds)" >> "$OUT/pipeline.log"
