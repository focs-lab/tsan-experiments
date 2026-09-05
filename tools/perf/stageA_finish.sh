#!/bin/bash
# stageA_finish.sh <hash> — close out the two items the probe overlap disturbed, in order, under the lock:
#   1. FFmpeg run1 of every configuration: those four runs overlapped the placement probe, which was pinned to
#      the same 48 CPUs because probes did not take the benchmark lock (they do now). They were quarantined as
#      run1.probe-overlap; a second pass of run.sh refills the gap and skips the runs that are already good.
#   2. the memcached placement probe itself, which never produced valid data (it did not source configs.sh, so
#      the server binary path was empty and no server ever started).
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh
HASH=${1:?}; OUT="$P5_DIR/results/$(date +%F)-$HASH"
until grep -q "STAGE-A-FFMPEG-4T DONE" "$OUT/pipeline.log" 2>/dev/null; do sleep 120; done
p5_log "refilling the FFmpeg run1 gap left by the probe overlap"
FF_THREADS=4 ./run.sh ffmpeg "$HASH" 3 >> "$OUT/run-ffmpeg-4threads.log" 2>&1 || p5_log "ffmpeg refill exited non-zero"
p5_log "memcached placement probe (second retry, now holding the lock)"
./memcached_placement_probe.sh "$HASH" 5 > "$OUT/placement.log" 2>&1
cp "$OUT-placement/placement.md" "$OUT/placement.md" 2>/dev/null
python3 aggregate.py "$OUT" > /dev/null 2>&1
python3 write_readme_results.py "$OUT" > /dev/null 2>&1
echo "STAGE-A-RERUNS DONE $(date -Iseconds)" >> "$OUT/pipeline.log"
