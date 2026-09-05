#!/bin/bash
# stageA_reruns.sh <hash> — the two Stage A gaps, once the probes are done and the machine is quiet again:
#   1. memcached orig/tsan run1 (they came from the 14:14 smoke, before the CPU-accounting fix, and were the
#      only runs in the tree measured with the old metric),
#   2. the memcached placement probe, which died instantly on `local name=$1 ... d="$OUT/$name/..."`:
#      all words of a `local` are expanded before it runs, so $name was still unset under `set -u`.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh
HASH=${1:?}; OUT="$P5_DIR/results/$(date +%F)-$HASH"
until grep -q "STAGE-A-CPUSCALE DONE" "$OUT/pipeline.log" 2>/dev/null; do sleep 120; done
p5_log "re-running the two pre-fix memcached runs"
./run.sh memcached "$HASH" 1 --configs "orig tsan" >> "$OUT/run-memcached.log" 2>&1 || p5_log "memcached re-run exited non-zero"
p5_log "memcached placement probe (retry, N=5)"
./memcached_placement_probe.sh "$HASH" 5 > "$OUT/placement.log" 2>&1
cp "$OUT-placement/placement.md" "$OUT/placement.md" 2>/dev/null
python3 aggregate.py "$OUT" > /dev/null 2>&1
python3 write_readme_results.py "$OUT" > /dev/null 2>&1
echo "STAGE-A-RERUNS DONE $(date -Iseconds)" >> "$OUT/pipeline.log"
