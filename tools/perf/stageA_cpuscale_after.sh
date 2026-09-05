#!/bin/bash
# stageA_cpuscale_after.sh <hash> — run the SQLite CPU-count probe after the layout probe, on a quiet machine.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh
HASH=${1:?}; OUT="$P5_DIR/results/$(date +%F)-$HASH"
until grep -q "STAGE-A-LAYOUT DONE" "$OUT/pipeline.log" 2>/dev/null; do sleep 60; done
for pid in $(pgrep -f "build_config[s]\.sh $HASH"); do
  for c in $(pgrep -P "$pid"); do kill -TERM "$c" 2>/dev/null; done; kill -TERM "$pid" 2>/dev/null; done
for pid in $(pgrep -x ninja); do kill -TERM "$pid" 2>/dev/null; done
sleep 10
p5_log "SQLite CPU-count probe (48 vs 96 CPUs, tsan vs AllOpt-peel)"
./sqlite_cpuscale_probe.sh "$HASH" 2 > "$OUT/cpuscale.log" 2>&1
cp "$OUT-cpuscale/cpuscale.md" "$OUT/cpuscale.md" 2>/dev/null
echo "STAGE-A-CPUSCALE DONE $(date -Iseconds)" >> "$OUT/pipeline.log"
p5_log "cpuscale probe done; resuming the two nearly-finished Chromium builds"
( cd ../../chromium; setsid nohup ./build_configs.sh "$HASH" tsan > build-stageA-chromium-1.log 2>&1 < /dev/null &
  sleep 2; setsid nohup ./build_configs.sh "$HASH" tsan-sound > build-stageA-chromium-2.log 2>&1 < /dev/null & )
