#!/bin/bash
# memcached_placement_probe.sh <hash> [N=4] — two questions the interference pilot left open:
#   (a) is the memcached bimodality (85-88 s / 103-107 s per run) caused by client and server sharing the
#       pinned CPUs, and
#   (b) is the tsan-sound build really ~17 % slower than stock TSan on memcached, or does it just land in the
#       slow mode more often?
# Three placements of the paper workload (memtier -t 10 -x 5 --pipeline 16, 500 connections), each for both
# configurations, alternating config within a run index so drift cannot favour one:
#   shared48  server -t 48 and memtier both on 4-27,60-83          (what Stage A does)
#   split     server -t 40 on 4-23,60-79, memtier on 24-27,80-83   (disjoint client and server CPUs)
#   shared24  server -t 24 and memtier both on 4-27,60-83          (half as many server threads as CPUs)
# Output: placement.md — median/mean/sigma/CV and the wall-time range per (placement, config).
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh; source ./configs.sh   # p5_binary needs p5_base/p5_tag from configs.sh
HASH=${1:?}; N=${2:-4}; APPDIR=$(p5_app_dir memcached)
OUT="$P5_DIR/results/$(date +%F)-$HASH-placement"; mkdir -p "$OUT"
export TSAN_OPTIONS="report_bugs=0"
exec 9>"$P5_LOCK"; flock -x 9      # a probe is a benchmark: never run one beside a sweep
run_one() { # <placement> <cfg> <server-cpuset> <server-threads> <client-cpuset> <k>
  local name=$1 cfg=$2 scpu=$3 sthr=$4 ccpu=$5 k=$6
  local d="$OUT/$name/$cfg/run$k"          # separate statement: `local a=$1 b="$a"` leaves b unset under set -u
  local bin; bin=$(p5_binary memcached "$cfg"); mkdir -p "$d"
  (echo > /dev/tcp/127.0.0.1/7777) 2>/dev/null && { echo "port busy, skipping $name/$cfg/run$k"; return 1; }
  taskset -c "$scpu" "$bin" -c 4096 -t "$sthr" -p 7777 -U 0 > "$d/server.out" 2>&1 & local spid=$!
  local i; for i in $(seq 1 60); do (echo > /dev/tcp/127.0.0.1/7777) 2>/dev/null && break; sleep 1; done; sleep 1
  local t0=$(date +%s)
  taskset -c "$ccpu" "$APPDIR/memtier_benchmark-2.1.1/memtier_benchmark" --hide-histogram -t 10 -p 7777 \
     -x 5 --pipeline 16 -P memcache_text --random-data > "$d/memtier.txt" 2> "$d/err.log"
  local t1=$(date +%s); echo "$((t1-t0))" > "$d/seconds"
  kill -TERM "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
  for i in $(seq 1 30); do (echo > /dev/tcp/127.0.0.1/7777) 2>/dev/null || break; sleep 1; done
}
for k in $(seq 1 "$N"); do
  for cfg in tsan tsan-sound; do
    run_one shared48 "$cfg" 4-27,60-83 48 4-27,60-83  "$k"
    run_one split    "$cfg" 4-23,60-79 40 24-27,80-83 "$k"
    run_one shared24 "$cfg" 4-27,60-83 24 4-27,60-83  "$k"
  done
  p5_log "placement probe: run $k of $N done"
done
python3 - "$OUT" <<'PY2'
import glob, os, statistics as st, sys
root = sys.argv[1]; rows = []
for name in ("shared48", "split", "shared24"):
    for cfg in ("tsan", "tsan-sound"):
        xs, ts = [], []
        for d in sorted(glob.glob(f"{root}/{name}/{cfg}/run*")):
            sec = False
            for line in open(f"{d}/memtier.txt", errors="replace"):
                if "AGGREGATED AVERAGE" in line: sec = True
                elif sec and line.startswith("Totals"): xs.append(float(line.split()[1])); break
            if os.path.exists(f"{d}/seconds"): ts.append(int(open(f"{d}/seconds").read().strip()))
        if xs: rows.append((name, cfg, len(xs), st.median(xs), st.mean(xs),
                            st.stdev(xs) if len(xs) > 1 else 0.0, min(ts), max(ts)))
L = ["# memcached placement probe (paper workload, stock TSan vs the sound bundle)\n",
     "| placement | config | N | median ops/s | mean | sigma | CV | wall s |", "|---|---|---|---|---|---|---|---|"]
for n, c, k, med, mean, sd, tmin, tmax in rows:
    L.append(f"| {n} | {c} | {k} | {med:.0f} | {mean:.0f} | {sd:.0f} | {100*sd/mean:.1f} % | {tmin}-{tmax} |")
med = {(n, c): m for n, c, k, m, *_ in rows}
L.append("")
for n in ("shared48", "split", "shared24"):
    if (n, "tsan") in med and (n, "tsan-sound") in med:
        L.append(f"- {n}: tsan-sound / tsan = {med[(n,'tsan-sound')] / med[(n,'tsan')]:.3f}")
open(f"{root}/placement.md", "w").write("\n".join(L) + "\n"); print("\n".join(L))
PY2
