#!/bin/bash
# stageA_pipeline.sh <hash> — after the MySQL builds: pause the Chromium builds, run the interference pilot and
# the Stage A benchmarks of the five applications (N=3, pinned, one at a time), then resume the Chromium builds.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh; source ./configs.sh
HASH=${1:?}; N=${N:-3}; export MYSQL_SECONDS=${MYSQL_SECONDS:-60}
OUT="$P5_DIR/results/$(date +%F)-$HASH"; export P5_OUT="$OUT"
until grep -q "builds of mysql done" build-stageA-mysql.log 2>/dev/null; do sleep 60; done
grep -q "fail=0" build-stageA-mysql.log || p5_log "warning: some MySQL builds failed (see build-stageA-mysql.log)"
# pause the Chromium builds: stop their build_configs.sh + ninja (they resume incrementally when restarted)
p5_log "pausing Chromium builds"
for pid in $(pgrep -f "build_configs\.s[h] $HASH"); do pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; done
pkill -TERM -f "ninja -C out/chrome-" 2>/dev/null; sleep 10
p5_log "interference pilot"
./pilot_interference.sh "$HASH" 3 > "$OUT/pilot.log" 2>&1; cp "$OUT-pilot/pilot.md" "$OUT/pilot.md" 2>/dev/null
for app in memcached sqlite redis ffmpeg mysql; do
  p5_log "Stage A benchmarks: $app (N=$N)"
  ./run.sh "$app" "$HASH" "$N" > "$OUT/run-$app.log" 2>&1 || p5_log "run.sh $app exited non-zero"
  python3 aggregate.py "$OUT" --app "$app" > /dev/null 2>&1 || true
done
python3 aggregate.py "$OUT" > /dev/null 2>&1
p5_log "Stage A application benchmarks done; resuming Chromium builds"
( cd ../../chromium; setsid nohup ./build_configs.sh "$HASH" tsan tsan-dom-ea-lo-st-swmr > build-stageA-chromium-1.log 2>&1 < /dev/null & sleep 2; setsid nohup ./build_configs.sh "$HASH" tsan-sound > build-stageA-chromium-2.log 2>&1 < /dev/null & )
echo "STAGE-A-APPS DONE" >> "$OUT/pipeline.log"
