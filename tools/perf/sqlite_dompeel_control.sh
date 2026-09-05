#!/bin/bash
# sqlite_dompeel_control.sh — same-window control for the surprising SQLite DE+Peeling result (1.478 vs AllOpt 1.051):
# stock TSan, DE+Peeling and AllOpt-peel measured back to back now, N=3, into their own tree, so the comparison
# does not depend on yesterday's baseline runs. Chromium builds are stopped for the duration (anchored patterns:
# never let a pgrep -f pattern match the shell that launched this file).
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh
HASH=729521af8965; OUT="$P5_DIR/results/2026-09-04-$HASH-dompeel-control"; mkdir -p "$OUT"
for pid in $(pgrep -f "^/bin/bash \./build_configs\.sh $HASH"); do for c in $(pgrep -P "$pid"); do kill -TERM "$c" 2>/dev/null; done; kill -TERM "$pid" 2>/dev/null; done
for pid in $(pgrep -x ninja); do kill -TERM "$pid" 2>/dev/null; done; sleep 8
p5_log "same-window control: sqlite tsan / tsan-dom_peeling / tsan-dom-ea-lo-st-swmr, N=3"
P5_OUT="$OUT" ./run.sh sqlite "$HASH" 3 --configs "tsan tsan-dom_peeling tsan-dom-ea-lo-st-swmr" > "$OUT/run.log" 2>&1
python3 aggregate.py "$OUT" --app sqlite > /dev/null 2>&1
echo "SQLITE-DOMPEEL-CONTROL DONE $(date -Iseconds)" >> "$P5_DIR/results/2026-09-04-$HASH/pipeline.log"
p5_log "control done; resuming the two Chromium builds"
( cd ../../chromium; setsid nohup ./build_configs.sh "$HASH" tsan > build-stageA-chromium-1.log 2>&1 < /dev/null &
  sleep 2; setsid nohup ./build_configs.sh "$HASH" tsan-sound > build-stageA-chromium-2.log 2>&1 < /dev/null & )
