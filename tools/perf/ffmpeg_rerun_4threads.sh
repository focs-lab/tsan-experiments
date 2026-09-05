#!/bin/bash
# ffmpeg_rerun_4threads.sh <hash> — re-measure FFmpeg with the paper's -threads 4.
# The first Stage A pass used the pinned CPU count (48), which libx265 rejects (frame threads are capped at
# X265_MAX_FRAME_THREADS = 16): the h265 encode failed on every build and the codec disappeared from the
# tables, and the surviving codecs were measured at a thread count the paper never used (mjpeg 76 s in March
# at 4 threads, 202 s here at 48).  The 48-thread data is kept as ffmpeg-threads48/ — it is the evidence for
# how strongly this workload depends on the thread count.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh
HASH=${1:?}; N=${N:-3}; OUT="$P5_DIR/results/$(date +%F)-$HASH"
until grep -q "STAGE-A-CPUSCALE DONE" "$OUT/pipeline.log" 2>/dev/null; do sleep 120; done
if [ -d "$OUT/ffmpeg" ] && [ ! -d "$OUT/ffmpeg-threads48" ]; then
  mv "$OUT/ffmpeg" "$OUT/ffmpeg-threads48"; p5_log "kept the 48-thread FFmpeg pass as ffmpeg-threads48/"
fi
p5_log "FFmpeg re-run with -threads 4 (the paper's setting), N=$N"
FF_THREADS=4 ./run.sh ffmpeg "$HASH" "$N" > "$OUT/run-ffmpeg-4threads.log" 2>&1 || p5_log "run.sh ffmpeg exited non-zero"
python3 aggregate.py "$OUT" > /dev/null 2>&1
python3 write_readme_results.py "$OUT" > /dev/null 2>&1
echo "STAGE-A-FFMPEG-4T DONE $(date -Iseconds)" >> "$OUT/pipeline.log"
