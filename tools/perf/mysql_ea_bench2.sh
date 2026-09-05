#!/bin/bash
# mysql_ea_bench2.sh <hash> — benchmark the optimised MySQL configurations once the rest of Stage A is done.
# The earlier chain resumed the Chromium builds immediately after each MySQL configuration, which would have
# put a 40-way build beside the probes still queued behind it; this one touches Chromium only at the very end.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh
HASH=${1:?}; N=${N:-3}; OUT="$P5_DIR/results/$(date +%F)-$HASH"
INSTALLS=/extra/alexey/tsan-experiments/installs
until grep -q "STAGE-A-COMPLETE" "$OUT/pipeline.log" 2>/dev/null; do sleep 120; done
for cfg in tsan-sound tsan-dom-ea-lo-st-swmr tsan-dom_peeling-ea-lo-st-swmr; do
  [ -d "$OUT/mysql/$cfg" ] && { p5_log "mysql $cfg already measured"; continue; }
  bin="$INSTALLS/mysql-$cfg/bin/mysqld"
  p5_log "waiting for the MySQL $cfg build"
  waited=0
  while { [ ! -x "$bin" ] || [ ! -f "$INSTALLS/mysql-$cfg/build_info.txt" ]; } && [ $waited -lt 28800 ]; do sleep 300; waited=$((waited+300)); done
  [ -x "$bin" ] || { p5_log "MySQL $cfg not built after 8 h; skipping"; continue; }
  p5_log "Stage A benchmarks: mysql $cfg (N=$N, 60 s per sysbench script)"
  MYSQL_SECONDS=60 ./run.sh mysql "$HASH" "$N" --configs "$cfg" >> "$OUT/run-mysql.log" 2>&1 || p5_log "run.sh mysql $cfg exited non-zero"
  python3 aggregate.py "$OUT" > /dev/null 2>&1; python3 write_readme_results.py "$OUT" > /dev/null 2>&1
  echo "STAGE-A-MYSQL-$cfg DONE $(date -Iseconds)" >> "$OUT/pipeline.log"
done
p5_log "MySQL optimised configurations done; releasing the machine to the Chromium builds"
( cd ../../chromium; setsid nohup ./build_configs.sh "$HASH" tsan > build-stageA-chromium-1.log 2>&1 < /dev/null &
  sleep 2; setsid nohup ./build_configs.sh "$HASH" tsan-sound > build-stageA-chromium-2.log 2>&1 < /dev/null & )
