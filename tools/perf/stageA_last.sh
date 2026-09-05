#!/bin/bash
# stageA_last.sh <hash> — the final gap: FFmpeg's stock-TSan run1 was re-measured at outside_busy 0.288 and
# rejected, leaving the *baseline* of every FFmpeg ratio at N=2. run.sh's disturbed pass re-runs it.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh
HASH=${1:?}; OUT="$P5_DIR/results/$(date +%F)-$HASH"
until grep -q "STAGE-A-RERUNS DONE" "$OUT/pipeline.log" 2>/dev/null; do sleep 120; done
p5_log "re-running FFmpeg's rejected stock-TSan run"
FF_THREADS=4 ./run.sh ffmpeg "$HASH" 3 >> "$OUT/run-ffmpeg-4threads.log" 2>&1 || p5_log "ffmpeg exited non-zero"
python3 aggregate.py "$OUT" > /dev/null 2>&1
python3 write_readme_results.py "$OUT" > /dev/null 2>&1
echo "STAGE-A-COMPLETE $(date -Iseconds)" >> "$OUT/pipeline.log"
