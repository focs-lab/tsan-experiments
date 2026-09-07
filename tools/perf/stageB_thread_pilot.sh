#!/bin/bash
# stageB_thread_pilot.sh <hash> — which thread policy yields the larger speedups? (Alexey: "try those which give
# better performance"). memcached: server -t 48 (pinned-CPU rule) vs -t 112 (the paper's nproc rule); MySQL:
# sysbench 36 threads (¾ of 48) vs 84 (¾ of 112). Stock and sound only, N=3, 60 s sysbench, own results tree
# per policy so the sweep's tree stays clean. Output: thread_pilot.md with the sound/stock ratio per policy.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh; source ./configs.sh
HASH=${1:?}; N=${N:-3}; ROOT="$P5_DIR/results/stageB-$HASH-threadpilot"; mkdir -p "$ROOT"
export MYSQL_SECONDS=60
for pol in pinned paper; do
  if [ $pol = pinned ]; then MC=48; MY=36; else MC=112; MY=84; fi
  p5_log "thread pilot: policy=$pol memcached -t $MC, sysbench $MY threads"
  MC_THREADS=$MC P5_OUT="$ROOT/$pol" ./run.sh memcached "$HASH" "$N" --configs "tsan tsan-sound" > "$ROOT/run-memcached-$pol.log" 2>&1
  MYSQL_THREADS=$MY P5_OUT="$ROOT/$pol" ./run.sh mysql "$HASH" "$N" --configs "tsan tsan-sound" > "$ROOT/run-mysql-$pol.log" 2>&1
  python3 aggregate.py "$ROOT/$pol" > /dev/null 2>&1
done
python3 - "$ROOT" <<'PY2'
import json, sys, os, math, statistics as st
root = sys.argv[1]; g = lambda xs: math.exp(sum(map(math.log, xs)) / len(xs))
L = ["# Thread-policy pilot (stock vs sound, N=3)\n", "| app | policy | setting | SU sound/stock (geomean over tests) | stock median (first test) |", "|---|---|---|---|---|"]
for app in ("memcached", "mysql"):
    for pol, setting in (("pinned", "memcached -t 48 / sysbench 36"), ("paper", "memcached -t 112 / sysbench 84")):
        f = f"{root}/{pol}/perf_{app}.json"
        if not os.path.exists(f): L.append(f"| {app} | {pol} | {setting} | (missing) | |"); continue
        j = json.load(open(f)); b = j.get("tsan", {}).get("runs", {}); s = j.get("tsan-sound", {}).get("runs", {})
        tests = [k for k in b if not k.startswith("_") and k in s and b[k] and s[k]]
        if not tests: L.append(f"| {app} | {pol} | {setting} | (no runs) | |"); continue
        su = g([st.median(s[k]) / st.median(b[k]) for k in tests]); first = tests[0]
        L.append(f"| {app} | {pol} | {setting} | {su:.3f} | {first}: {st.median(b[first]):.0f} |")
open(f"{root}/thread_pilot.md", "w").write("\n".join(L) + "\n"); print("\n".join(L))
PY2
