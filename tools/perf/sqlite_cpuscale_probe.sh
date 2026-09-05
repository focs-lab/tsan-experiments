#!/bin/bash
# sqlite_cpuscale_probe.sh <hash> [N=2] — does SQLite's speedup depend on how many CPUs the workload gets?
# March measured threadtest3 unpinned on all 112 CPUs and stock TSan was 34.8x slower than native on `stress1`,
# which is what carries the paper's SQLite geometric mean (2.77x for AllOpt-peel).  Stage A pins to 48 CPUs and
# the same subtest shows stock TSan only ~3.4x slower, i.e. most of the effect is contention relief, not
# instrumentation cost.  This probe measures the same two configurations on 48 and on 96 CPUs.
# CPUs 52-55,108-111 are left out of both sets: our parked MySQL build lives there.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh
HASH=${1:?}; N=${2:-2}; APPDIR=$(p5_app_dir sqlite)
OUT="$P5_DIR/results/$(date +%F)-$HASH-cpuscale"; mkdir -p "$OUT"
exec 9>"$P5_LOCK"; flock -x 9      # a probe is a benchmark: never run one beside a sweep
for k in $(seq 1 "$N"); do
  for cpus in "4-27,60-83" "4-51,60-107"; do
    n=$(taskset -c "$cpus" nproc)
    for cfg in tsan tsan-dom-ea-lo-st-swmr; do
      d="$OUT/cpus$n/$cfg/run$k"; mkdir -p "$d"
      ( cd "$APPDIR" && taskset -c "$cpus" ./run_sqlite_test.sh "$cfg" ) > "$d/cmd.log" 2>&1
      cp "$APPDIR/results/$cfg.log" "$d/threadtest3.log" 2>/dev/null
      p5_log "cpuscale: $n CPUs, $cfg, run $k"
    done
  done
done
python3 - "$OUT" <<'PY2'
import sys, os, glob, statistics as st, math
sys.path.insert(0, "../../sql/sqlite")
import parse_results as P
root = sys.argv[1]
data = {}
for cd in sorted(glob.glob(f"{root}/cpus*")):
    n = os.path.basename(cd)[4:]
    for cfg in sorted(os.listdir(cd)):
        runs = []
        for d in sorted(glob.glob(f"{cd}/{cfg}/run*")):
            f = f"{d}/threadtest3.log"
            if os.path.exists(f):
                try: runs.append(P.parse_log_file(f))
                except Exception: pass
        if runs: data[(n, cfg)] = runs
L = ["# SQLite: how the speedup depends on the number of CPUs\n",
     "Median over runs per subtest; SU = AllOpt-peel / stock TSan (higher is better).\n",
     "| CPUs | subtest | tsan | AllOpt-peel | SU |", "|---|---|---|---|---|"]
for n in sorted({k[0] for k in data}, key=int):
    base = data.get((n, "tsan")); opt = data.get((n, "tsan-dom-ea-lo-st-swmr"))
    if not base or not opt: continue
    sus = []
    for t in base[0]:
        b = st.median([r[t] for r in base if t in r]); o = st.median([r[t] for r in opt if t in r])
        if b: sus.append(o / b); L.append(f"| {n} | {t} | {b:.0f} | {o:.0f} | {o/b:.2f} |")
    if sus: L.append(f"| **{n}** | **geomean** | | | **{math.exp(sum(map(math.log, sus))/len(sus)):.3f}** |")
open(f"{root}/cpuscale.md", "w").write("\n".join(L) + "\n"); print("\n".join(L))
PY2
