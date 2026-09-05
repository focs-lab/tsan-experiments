#!/bin/bash
# sqlite_singles_rebuild.sh — rebuild every single-analysis SQLite configuration from the frozen 729521af8965
# copy (build.sh verifies the stamp and archives the 2026-09-02 pre-audit dirs to old-builds/), then re-measure
# tsan-dom_peeling N=3 under the lock with the new provenance gate, then hand the machine to the Chromium builds.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh
HASH=729521af8965; OUT="$P5_DIR/results/2026-09-04-$HASH"
p5_log "rebuilding SQLite single-analysis configurations from the frozen copy"
taskset -c 52-54,108-110 nice -n 10 ./build.sh sqlite "$HASH" "tsan-dom tsan-dom_peeling tsan-ea tsan-lo tsan-st tsan-stmt tsan-swmr" > "$OUT/build/sqlite-singles-rebuild.log" 2>&1
for c in tsan-dom tsan-dom_peeling tsan-ea tsan-lo tsan-st tsan-stmt tsan-swmr; do printf "  %-18s %s\n" "$c" "$(grep -m1 '^compiler_head:' ../../sql/sqlite/build/test-$c/build_info.txt 2>/dev/null | awk '{print substr($2,1,12)}')"; done
p5_log "re-measuring sqlite tsan-dom_peeling (N=3) on the fresh binary"
P5_OUT="$OUT" ./run.sh sqlite "$HASH" 3 --configs "tsan-dom_peeling" >> "$OUT/run-sqlite.log" 2>&1 || p5_log "run.sh exited non-zero"
python3 aggregate.py "$OUT" --app sqlite > /dev/null 2>&1; python3 write_readme_results.py "$OUT" > /dev/null 2>&1
echo "SQLITE-DOMPEEL-CORRECTED DONE $(date -Iseconds)" >> "$OUT/pipeline.log"
p5_log "done; resuming the two Chromium builds"
( cd ../../chromium && setsid nohup ./build_configs.sh "$HASH" tsan > build-stageA-chromium-1.log 2>&1 < /dev/null &
  sleep 2; setsid nohup ./build_configs.sh "$HASH" tsan-sound > build-stageA-chromium-2.log 2>&1 < /dev/null & )
