#!/bin/bash
# layout_probe.sh <hash> [N=3] — is memcached's sticky slow mode a property of the binary's code layout?
# The sound build is ~17 % slower than stock TSan on memcached while carrying strictly *less* instrumentation
# (no function has more __tsan_ calls than in stock).  Code layout is the usual explanation for a difference of
# that size.  Test: rebuild the same configuration with three function alignments, which changes layout and
# nothing else, and measure each.  If the spread across alignments is of the same order as the sound-vs-stock
# gap, the gap is layout, not the analyses.
# Builds go to memcached-<cfg>-align<N> (BUILD_TAG), so the Stage A binaries are untouched.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh
HASH=${1:?}; N=${2:-3}; CFG=${CFG:-tsan-sound}; APPDIR=$(p5_app_dir memcached)
OUT="$P5_DIR/results/$(date +%F)-$HASH-layout"; mkdir -p "$OUT"
export LLVM_TSAN_ROOT="$P5_BUILDS/tsan-dev-$HASH" TSAN_OPTIONS="report_bugs=0"
exec 9>"$P5_LOCK"; flock -x 9      # a probe is a benchmark: never run one beside a sweep
for a in 16 32 64; do
  d="$APPDIR/memcached-$CFG-align$a"
  [ -x "$d/memcached" ] || ( cd "$APPDIR" && EXTRA_TSAN_FLAGS="-falign-functions=$a" BUILD_TAG="-align$a" \
      nice -n 10 ./build_memcached.sh "$CFG" ) > "$OUT/build-align$a.log" 2>&1
  [ -x "$d/memcached" ] || { echo "build failed for align$a, see $OUT/build-align$a.log"; exit 1; }
done
run_one() { # <align> <k>
  local a=$1 k=$2
  local d="$OUT/align$a/run$k"; mkdir -p "$d"
  (echo > /dev/tcp/127.0.0.1/7777) 2>/dev/null && { echo "port busy"; return 1; }
  taskset -c 4-27,60-83 "$APPDIR/memcached-$CFG-align$a/memcached" -c 4096 -t 48 -p 7777 -U 0 > "$d/server.out" 2>&1 & local spid=$!
  local i; for i in $(seq 1 60); do (echo > /dev/tcp/127.0.0.1/7777) 2>/dev/null && break; sleep 1; done; sleep 1
  local t0=$(date +%s)
  taskset -c 4-27,60-83 "$APPDIR/memtier_benchmark-2.1.1/memtier_benchmark" --hide-histogram -t 10 -p 7777 \
     -x 5 --pipeline 16 -P memcache_text --random-data > "$d/memtier.txt" 2> "$d/err.log"
  echo "$(( $(date +%s) - t0 ))" > "$d/seconds"
  kill -TERM "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
  for i in $(seq 1 30); do (echo > /dev/tcp/127.0.0.1/7777) 2>/dev/null || break; sleep 1; done
}
for k in $(seq 1 "$N"); do for a in 16 32 64; do run_one "$a" "$k"; done; p5_log "layout probe: run $k of $N done"; done
python3 - "$OUT" "$CFG" <<'PY2'
import glob, os, statistics as st, sys
root, cfg = sys.argv[1], sys.argv[2]; rows = []
for a in ("16", "32", "64"):
    xs, ts = [], []
    for d in sorted(glob.glob(f"{root}/align{a}/run*")):
        sec = False
        for line in open(f"{d}/memtier.txt", errors="replace"):
            if "AGGREGATED AVERAGE" in line: sec = True
            elif sec and line.startswith("Totals"): xs.append(float(line.split()[1])); break
        if os.path.exists(f"{d}/seconds"): ts.append(int(open(f"{d}/seconds").read().strip()))
    if xs: rows.append((a, len(xs), st.median(xs), st.mean(xs), st.stdev(xs) if len(xs) > 1 else 0.0, min(ts), max(ts)))
L = [f"# memcached layout probe — {cfg} rebuilt at three function alignments\n",
     "| -falign-functions | N | median ops/s | mean | sigma | CV | wall s |", "|---|---|---|---|---|---|---|"]
for a, k, med, mean, sd, tmin, tmax in rows:
    L.append(f"| {a} | {k} | {med:.0f} | {mean:.0f} | {sd:.0f} | {100*sd/mean:.1f} % | {tmin}-{tmax} |")
if len(rows) > 1:
    meds = [r[2] for r in rows]
    L.append(f"\nSpread across alignments: {100*(max(meds)-min(meds))/min(meds):.1f} % of the slowest median.")
open(f"{root}/layout.md", "w").write("\n".join(L) + "\n"); print("\n".join(L))
PY2
