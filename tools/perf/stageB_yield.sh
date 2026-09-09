#!/bin/bash
# stageB_yield.sh — the yield stage: build and measure the A/B pairs inside one compiler copy
# (/extra/alexey/builds/tsan-yield-d98873cda906 = stage-b2 c38c1e7e94ec + the seven yield changes, every change
# behind a -mllvm switch that defaults to on). A "-yoff" row turns all six switches off, so a pair differs only
# by the yield changes and never by the stage-b2 changes underneath them.
# Builds first (all four applications concurrently, minutes each on this compiler), then one measurement at a
# time under the machine lock. Fast applications first so the answer lands before SQLite's long leg.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh; source ./configs.sh
Y=${1:-d98873cda906}; N=${N:-5}
OUT="$P5_DIR/results/yield-$Y"; mkdir -p "$OUT/build"
export P5_OUT="$OUT" FF_THREADS="${FF_THREADS:-4}" MC_REQUESTS="${MC_REQUESTS:-100000}" P5_FOREIGN_MAX="${P5_FOREIGN_MAX:-0.10}"

p5_log "yield stage: builds ($P5_YIELD_APPS)" | tee -a "$OUT/sweep.log"
for app in $P5_YIELD_APPS; do
  P5_OUT="$OUT" ./build.sh "$app" "$Y" "$P5_YIELD" > "$OUT/build/build-$app.log" 2>&1 &
done; wait
echo "YIELD-BUILDS DONE $(date -Iseconds)" >> "$OUT/pipeline.log"
python3 static_diff.py results/stageB-d3bf9f8c39fe "$OUT" > "$OUT/static-diff-vs-stage-b.md" 2>&1

for app in memcached redis ffmpeg sqlite; do
  case " $P5_YIELD_APPS " in *" $app "*) ;; *) continue;; esac
  p5_log "yield leg: $app N=$N" | tee -a "$OUT/sweep.log"
  ./run.sh "$app" "$Y" "$N" --configs "$P5_YIELD" > "$OUT/run-$app.log" 2>&1 || p5_log "run.sh $app exited non-zero"
  python3 aggregate.py "$OUT" --app "$app" > /dev/null 2>&1
  echo "YIELD-$app DONE $(date -Iseconds)" >> "$OUT/pipeline.log"
done
python3 aggregate.py "$OUT" > /dev/null 2>&1
N=$N P5_TOPUP_OUT="$OUT" ./stageB_topup.sh "$Y" > "$OUT/topup.log" 2>&1
# the paired A/B is the point of this stage: <config> against <config>-yoff inside the one compiler
python3 yield_pairs.py "$OUT" > "$OUT/yield_pairs.log" 2>&1
python3 write_readme_results.py results/stageB-d3bf9f8c39fe "$OUT" > /dev/null 2>&1
echo "YIELD-SWEEP DONE $(date -Iseconds)" >> "$OUT/pipeline.log"
