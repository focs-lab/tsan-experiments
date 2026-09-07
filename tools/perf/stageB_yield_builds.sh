#!/bin/bash
# stageB_yield_builds.sh — build the yield copy's main rows for all five applications once the stage-b extra
# builds have finished (never two MySQL builds at once). Builds only.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh
Y=fdf7a4dd41e9; B=results/stageB-d3bf9f8c39fe/build; OUT="$P5_DIR/results/stageB-$Y"; mkdir -p "$OUT/build"
until [ "$(grep -l 'builds of .* done' $B/build-*-extra.log 2>/dev/null | wc -l)" -ge 5 ]; do sleep 120; done
p5_log "stage-b extra builds done; building the yield copy's main rows"
for app in memcached redis sqlite ffmpeg mysql; do
  cfgs="tsan tsan-sound tsan-dom-ea-lo-st-swmr tsan-dom_peeling-ea-lo-st-swmr tsan-stmt"
  [ $app = mysql ] || [ $app = ffmpeg ] || cfgs="$cfgs tsan-sound-wp"
  P5_OUT="$OUT" ./build.sh $app $Y "orig $cfgs" > "$OUT/build/build-$app.log" 2>&1 &
done; wait
echo "YIELD BUILDS DONE $(date -Iseconds)" >> "$OUT/build/builds.log"
python3 static_diff.py results/stageB-d3bf9f8c39fe "$OUT" > "$OUT/static-diff-vs-stage-b.md" 2>&1
