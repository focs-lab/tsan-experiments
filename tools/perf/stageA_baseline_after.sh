#!/bin/bash
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh
HASH=${1:?}; OUT="$P5_DIR/results/$(date +%F)-$HASH"
until grep -q "STAGE-A-RERUNS DONE" "$OUT/pipeline.log" 2>/dev/null; do sleep 120; done
p5_log "SQLite stock-TSan baseline probe (final compiler vs paper compiler)"
./sqlite_baseline_probe.sh "$HASH" 2 > "$OUT/baseline.log" 2>&1
cp "$OUT-baseline/baseline.md" "$OUT/baseline.md" 2>/dev/null
echo "STAGE-A-BASELINE DONE $(date -Iseconds)" >> "$OUT/pipeline.log"
