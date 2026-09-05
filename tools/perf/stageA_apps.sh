#!/bin/bash
# stageA_apps.sh <hash> — Stage A benchmarks for the applications whose builds are complete.
# MySQL is excluded: on 729521af8965 the escape analysis does not terminate in reasonable time on
# mysql/sql_yacc.cc (see tools/notes/ea-compile-time-2026-09-04.md), so its optimised configs have no binary.
# Chromium builds must be stopped before this runs (they use every CPU); they are resumed at the end.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh; source ./configs.sh
HASH=${1:?}; N=${N:-3}; APPS=${APPS:-"memcached sqlite redis ffmpeg"}
OUT="$P5_DIR/results/$(date +%F)-$HASH"; export P5_OUT="$OUT"; mkdir -p "$OUT"
p5_log "interference pilot (memcached alone vs paired with sqlite)"
./pilot_interference.sh "$HASH" 3 > "$OUT/pilot.log" 2>&1; cp "$OUT-pilot/pilot.md" "$OUT/pilot.md" 2>/dev/null
for app in $APPS; do
  p5_log "Stage A benchmarks: $app (N=$N)"
  ./run.sh "$app" "$HASH" "$N" > "$OUT/run-$app.log" 2>&1 || p5_log "run.sh $app exited non-zero"
  python3 aggregate.py "$OUT" --app "$app" > /dev/null 2>&1 || true
done
python3 aggregate.py "$OUT" > /dev/null 2>&1
p5_log "Stage A application benchmarks done; resuming Chromium builds"
( cd ../../chromium; setsid nohup ./build_configs.sh "$HASH" tsan tsan-dom-ea-lo-st-swmr > build-stageA-chromium-1.log 2>&1 < /dev/null & sleep 2; setsid nohup ./build_configs.sh "$HASH" tsan-sound > build-stageA-chromium-2.log 2>&1 < /dev/null & )
echo "STAGE-A-APPS DONE $(date -Iseconds)" >> "$OUT/pipeline.log"
