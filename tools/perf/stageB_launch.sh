#!/bin/bash
# stageB_launch.sh — start the Stage B pilot + sweep on d3bf9f8c39fe when BOTH hold: every stage-b extra build
# has finished, and the quiet window has been granted (touch results/stageB-d3bf9f8c39fe/GO after tsan-dev's ack).
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh
H=d3bf9f8c39fe; B=results/stageB-$H/build
until [ "$(grep -l 'builds of .* done' $B/build-*-extra.log 2>/dev/null | wc -l)" -ge 5 ] && [ -f results/stageB-$H/GO ]; do sleep 60; done
p5_log "builds done and GO present: starting the Stage B pilot + sweep on $H"
./stageB_sweep.sh "$H" > results/stageB-$H/sweep.log 2>&1
