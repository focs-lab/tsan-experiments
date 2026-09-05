#!/bin/bash
# pilot_interference.sh <hash> [N=3] — does a second benchmark in a disjoint cpuset change the numbers?
# Phase 1: memcached tsan+tsan-sound, N runs alone (cpuset A). Phase 2: the same while SQLite tsan runs in cpuset B.
# Compare per-config medians and the SU ratio between phases; if they agree within the run-to-run spread,
# paired benchmarking is acceptable. Output: results/<date>-<hash>-pilot/{alone,paired}/ and pilot.md
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh
HASH=${1:?}; N=${2:-3}; A="4-27,60-83"; B="28-51,84-107"
ROOT="$P5_DIR/results/$(date +%F)-$HASH-pilot"; mkdir -p "$ROOT"
p5_log "phase 1: memcached alone on $A (N=$N)"
P5_OUT="$ROOT/alone" ./run.sh memcached "$HASH" "$N" --configs "tsan tsan-sound" --cpuset "$A"
p5_log "phase 2: memcached on $A while sqlite tsan runs on $B"
# phase 2 runs two benchmarks on purpose: the second one is exactly the "foreign" CPU time the
# disturbance rule watches for, so the rule is switched off here (P5_FOREIGN_MAX=1).
( P5_OUT="$ROOT/paired" P5_LOCK=/tmp/p5-pilot-b.lock P5_FOREIGN_MAX=1 ./run.sh sqlite "$HASH" "$N" --configs "tsan" --cpuset "$B" > "$ROOT/paired-sqlite.log" 2>&1 ) &
sleep 20
P5_OUT="$ROOT/paired" P5_LOCK=/tmp/p5-pilot-a.lock P5_FOREIGN_MAX=1 ./run.sh memcached "$HASH" "$N" --configs "tsan tsan-sound" --cpuset "$A"
wait
python3 aggregate.py "$ROOT/alone" --app memcached > /dev/null; python3 aggregate.py "$ROOT/paired" --app memcached > /dev/null
python3 - "$ROOT" <<'PY'
import json, sys, statistics as st
root = sys.argv[1]; out = []
for ph in ("alone", "paired"):
    j = json.load(open(f"{root}/{ph}/perf_memcached.json"))
    for cfg, d in j.items():
        xs = d["runs"]["ops_sec"]; out.append((ph, cfg, len(xs), st.median(xs), st.mean(xs), st.stdev(xs) if len(xs) > 1 else 0))
lines = ["# Interference pilot (memcached alone vs. alongside SQLite in a disjoint cpuset)\n", "| phase | config | N | median ops/s | mean | σ | CV |", "|---|---|---|---|---|---|---|"]
for ph, cfg, n, med, mean, sd in out: lines.append(f"| {ph} | {cfg} | {n} | {med:.0f} | {mean:.0f} | {sd:.0f} | {100*sd/mean:.1f} % |")
def su(ph):
    m = {cfg: med for p, cfg, n, med, *_ in out if p == ph}; return m.get("tsan-sound", 0) / m.get("tsan", 1)
lines.append(f"\nSU(tsan-sound vs tsan): alone {su('alone'):.3f}, paired {su('paired'):.3f}")
open(f"{root}/pilot.md", "w").write("\n".join(lines) + "\n"); print("\n".join(lines))
PY
