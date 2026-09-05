#!/bin/bash
# stageA_layout_after.sh <hash> — run the memcached layout probe after the placement probe, while the machine is
# still quiet, then hand the machine back to the Chromium builds.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh
HASH=${1:?}; OUT="$P5_DIR/results/$(date +%F)-$HASH"
until grep -q "STAGE-A-PLACEMENT DONE" "$OUT/pipeline.log" 2>/dev/null; do sleep 60; done
for pid in $(pgrep -f "build_config[s]\.sh $HASH"); do
  for c in $(pgrep -P "$pid"); do kill -TERM "$c" 2>/dev/null; done; kill -TERM "$pid" 2>/dev/null; done
for pid in $(pgrep -x ninja); do kill -TERM "$pid" 2>/dev/null; done
sleep 10
p5_log "memcached layout probe (tsan-sound at three function alignments)"
./layout_probe.sh "$HASH" 3 > "$OUT/layout.log" 2>&1
cp "$OUT-layout/layout.md" "$OUT/layout.md" 2>/dev/null
echo "STAGE-A-LAYOUT DONE $(date -Iseconds)" >> "$OUT/pipeline.log"
p5_log "layout probe done; resuming the two nearly-finished Chromium builds"
( cd ../../chromium; setsid nohup ./build_configs.sh "$HASH" tsan > build-stageA-chromium-1.log 2>&1 < /dev/null &
  sleep 2; setsid nohup ./build_configs.sh "$HASH" tsan-sound > build-stageA-chromium-2.log 2>&1 < /dev/null & )
