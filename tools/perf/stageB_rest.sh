#!/bin/bash
# stageB_rest.sh <hash> — the remaining Stage B legs, strictly serial: SQLite, Redis, FFmpeg, MySQL.
# One measurement at a time (run.sh wraps each in machine-lock --measure, exclusive, 32G scope, bench cpus);
# nothing is built here. A boundary marker per leg lets the other lanes plan; the yield rows follow separately.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh; source ./configs.sh
HASH=${1:?}; N=${N:-5}; APPS=${APPS:-"sqlite redis ffmpeg mysql"}
OUT="$P5_DIR/results/stageB-$HASH"; export P5_OUT="$OUT" MYSQL_SECONDS="${MYSQL_SECONDS:-180}" FF_THREADS="${FF_THREADS:-4}"
for app in $APPS; do
  cfgs=$(p5_configs_for "$app" "$P5_ALL")
  p5_log "Stage B leg: $app N=$N ($(echo $cfgs | wc -w) configs)" | tee -a "$OUT/sweep.log"
  ./run.sh "$app" "$HASH" "$N" --configs "$cfgs" > "$OUT/run-$app.log" 2>&1 || p5_log "run.sh $app exited non-zero"
  python3 aggregate.py "$OUT" --app "$app" > /dev/null 2>&1
  python3 write_readme_results.py "$OUT" > /dev/null 2>&1
  echo "STAGE-B-$app DONE $(date -Iseconds)" >> "$OUT/pipeline.log"
  p5_log "Stage B leg done: $app" | tee -a "$OUT/sweep.log"
done
python3 aggregate.py "$OUT" > /dev/null 2>&1
echo "STAGE-B-SWEEP DONE $(date -Iseconds)" >> "$OUT/pipeline.log"
