#!/bin/bash
# mysql_ea_bench_chain.sh <hash> — benchmark each optimised MySQL configuration as soon as its (slow) build
# lands, so the MySQL column fills in overnight instead of waiting for all three.  Each build costs ~3 h in
# sql_yacc.cc alone (tools/notes/ea-compile-time-2026-09-04.md) and runs on the parked CPUs; this chain only
# benchmarks, one configuration at a time, with the Chromium builds paused around each run.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh
HASH=${1:?}; N=${N:-3}; OUT="$P5_DIR/results/$(date +%F)-$HASH"
INSTALLS=/extra/alexey/tsan-experiments/installs
pause_chromium() {
  for pid in $(pgrep -f "build_config[s]\.sh $HASH"); do
    for c in $(pgrep -P "$pid"); do kill -TERM "$c" 2>/dev/null; done; kill -TERM "$pid" 2>/dev/null; done
  for pid in $(pgrep -x ninja); do kill -TERM "$pid" 2>/dev/null; done; sleep 10; }
resume_chromium() {
  ( cd ../../chromium; setsid nohup ./build_configs.sh "$HASH" tsan > build-stageA-chromium-1.log 2>&1 < /dev/null &
    sleep 2; setsid nohup ./build_configs.sh "$HASH" tsan-sound > build-stageA-chromium-2.log 2>&1 < /dev/null & ); }
# do not compete with the Stage A probes
until grep -q "STAGE-A-CPUSCALE DONE" "$OUT/pipeline.log" 2>/dev/null; do sleep 120; done
for cfg in tsan-sound tsan-dom-ea-lo-st-swmr tsan-dom_peeling-ea-lo-st-swmr; do
  bin="$INSTALLS/mysql-$cfg/bin/mysqld"
  p5_log "waiting for the MySQL $cfg build"
  # give up after 8 h rather than wait for a build that failed
  waited=0
  while [ ! -x "$bin" ] && [ $waited -lt 28800 ]; do sleep 300; waited=$((waited + 300)); done
  [ -x "$bin" ] || { p5_log "MySQL $cfg not built after 8 h; skipping"; continue; }
  # the build script writes the binary before it finishes installing: wait for its build_info.txt too
  while [ ! -f "$INSTALLS/mysql-$cfg/build_info.txt" ]; do sleep 60; done
  pause_chromium
  p5_log "Stage A benchmarks: mysql $cfg (N=$N, 60 s per sysbench script)"
  MYSQL_SECONDS=60 ./run.sh mysql "$HASH" "$N" --configs "$cfg" >> "$OUT/run-mysql.log" 2>&1 || p5_log "run.sh mysql $cfg exited non-zero"
  python3 aggregate.py "$OUT" > /dev/null 2>&1
  python3 write_readme_results.py "$OUT" > /dev/null 2>&1
  echo "STAGE-A-MYSQL-$cfg DONE $(date -Iseconds)" >> "$OUT/pipeline.log"
  resume_chromium
done
p5_log "MySQL optimised configurations: chain finished"
