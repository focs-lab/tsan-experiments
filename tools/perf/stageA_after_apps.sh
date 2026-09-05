#!/bin/bash
# stageA_after_apps.sh <hash> — everything that must happen on a quiet machine after the four-application sweep:
#   1. pause the Chromium builds that stageA_apps.sh resumes,
#   2. MySQL adapter run (orig + tsan only — the optimised MySQL configurations are blocked by the escape-analysis
#      compile-time regression, tools/notes/ea-compile-time-2026-09-04.md),
#   3. memcached placement probe (the bimodality seen in the interference pilot),
#   4. resume the two Chromium builds that are ~75 % done (tsan, tsan-sound).  The third build
#      (tsan-dom-ea-lo-st-swmr, ~6 h from scratch) is left for after those two are benchmarked, so it does not
#      gate the methodology report.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh
HASH=${1:?}; OUT="$P5_DIR/results/$(date +%F)-$HASH"
pause_chromium() {
  for pid in $(pgrep -f "build_config[s]\\.sh $HASH"); do
    for c in $(pgrep -P "$pid"); do kill -TERM "$c" 2>/dev/null; done; kill -TERM "$pid" 2>/dev/null; done
  for pid in $(pgrep -x ninja); do kill -TERM "$pid" 2>/dev/null; done; sleep 10; }
until grep -q "STAGE-A-APPS DONE" "$OUT/pipeline.log" 2>/dev/null; do sleep 60; done
p5_log "after-apps: pausing Chromium builds"; pause_chromium
p5_log "Stage A benchmarks: mysql (orig,tsan only; N=3, 60 s per sysbench script)"
MYSQL_SECONDS=60 ./run.sh mysql "$HASH" 3 --configs "orig tsan" > "$OUT/run-mysql.log" 2>&1 || p5_log "run.sh mysql exited non-zero"
python3 aggregate.py "$OUT" > /dev/null 2>&1
echo "STAGE-A-MYSQL DONE $(date -Iseconds)" >> "$OUT/pipeline.log"
pause_chromium
p5_log "memcached placement probe (N=5 per placement)"
./memcached_placement_probe.sh "$HASH" 5 > "$OUT/placement.log" 2>&1
cp "$OUT-placement/placement.md" "$OUT/placement.md" 2>/dev/null
echo "STAGE-A-PLACEMENT DONE $(date -Iseconds)" >> "$OUT/pipeline.log"
p5_log "resuming the two nearly-finished Chromium builds"
( cd ../../chromium; setsid nohup ./build_configs.sh "$HASH" tsan > build-stageA-chromium-1.log 2>&1 < /dev/null &
  sleep 2; setsid nohup ./build_configs.sh "$HASH" tsan-sound > build-stageA-chromium-2.log 2>&1 < /dev/null & )
