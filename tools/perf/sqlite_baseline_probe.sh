#!/bin/bash
# sqlite_baseline_probe.sh <hash> [N=2] — can the paper's SQLite result be reproduced at all, on this machine?
# The paper's SQLite geometric mean (2.773 for AllOpt-peel) is carried by `stress1`, where the March artefacts
# show stock TSan at 6 417 iterations in 10 s; the same build and flags reach 85-105 k today at 48 or 96 CPUs,
# while *native* differs by only 1.2x. Ruled out already: subtest durations (identical), build flags (the
# March-era script, git 0632e34, has the same -g -O2 -fno-omit-frame-pointer and SQLite 3500200), race reports
# (none, report_bugs=0 both), machine width (the 48-vs-96 probe).
# Remaining variable: the compiler. This builds BOTH configurations with BOTH compilers and measures all four
# in one window, so the ratio can be compared within each compiler:
#   tsan, tsan-dom-ea-lo-st-swmr           final compiler 729521af8965
#   tsan-paper, tsan-dom-...-swmr-paper    paper compiler e90a3fc41004 (/extra/alexey/llvm-project-paper)
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh
HASH=${1:?}; N=${2:-2}; APPDIR=$(p5_app_dir sqlite)
OUT="$P5_DIR/results/$(date +%F)-$HASH-baseline"; mkdir -p "$OUT"
PAPER=/extra/alexey/llvm-project-paper/llvm/build
exec 9>"$P5_LOCK"; flock -x 9      # a probe is a benchmark: never run one beside a sweep
[ -x "$PAPER/bin/clang" ] || { echo "paper compiler not found at $PAPER"; exit 1; }
for cfg in tsan tsan-dom-ea-lo-st-swmr; do
  if [ ! -x "$APPDIR/build/test-$cfg-paper/threadtest3" ]; then
    p5_log "building sqlite $cfg with the paper compiler (e90a3fc41004)"
    ( cd "$APPDIR" && LLVM_TSAN_ROOT="$PAPER" BUILD_TAG="-paper" taskset -c 52-54,108-110 nice -n 10 \
        ./build_sqlite_test.sh "$cfg" ) > "$OUT/build-$cfg-paper.log" 2>&1 \
      || { echo "paper build of $cfg failed"; tail -5 "$OUT/build-$cfg-paper.log"; exit 1; }
  fi
done
for k in $(seq 1 "$N"); do
  for cfg in tsan tsan-paper tsan-dom-ea-lo-st-swmr tsan-dom-ea-lo-st-swmr-paper; do
    d="$OUT/$cfg/run$k"; mkdir -p "$d"
    ( cd "$APPDIR" && taskset -c 4-27,60-83 ./run_sqlite_test.sh "$cfg" ) > "$d/cmd.log" 2>&1
    cp "$APPDIR/results/$cfg.log" "$d/threadtest3.log" 2>/dev/null
    p5_log "baseline probe: $cfg run $k"
  done
done
python3 - "$OUT" <<'PY2'
import sys, os, glob, math, statistics as st, importlib.util
root = sys.argv[1]
spec = importlib.util.spec_from_file_location("sqp", "../../sql/sqlite/parse_results.py")
P = importlib.util.module_from_spec(spec); sys.modules["sqp"] = P; spec.loader.exec_module(P)
def med(cfg):
    runs = []
    for d in sorted(glob.glob(f"{root}/{cfg}/run*")):
        f = f"{d}/threadtest3.log"
        if os.path.exists(f):
            try: runs.append(P.parse_log_file(f))
            except Exception: pass
    if not runs: return None
    return {t: st.median([r[t] for r in runs if t in r]) for t in runs[0]}
final_b, final_o = med("tsan"), med("tsan-dom-ea-lo-st-swmr")
paper_b, paper_o = med("tsan-paper"), med("tsan-dom-ea-lo-st-swmr-paper")
march = {"walthread1": 1779, "walthread2": 3727, "dynamic_triggers": 61800, "checkpoint_starvation_1": 55417,
         "checkpoint_starvation_2": 766, "stress1": 6417, "stress2": 12536}
march_o = {"walthread1": 2853, "walthread2": 6066, "dynamic_triggers": 118800, "checkpoint_starvation_1": 149994,
           "checkpoint_starvation_2": 782, "stress1": 140582, "stress2": 52053}
L = ["# SQLite: is the paper's 2.77x reproducible? Both configurations, both compilers, one window\n",
     "Same source, same flags, same machine, 48 pinned CPUs. March values (one unpinned run on 112 CPUs) for reference.\n",
     "| subtest | tsan final | AllOpt-peel final | SU final | tsan paper | AllOpt-peel paper | SU paper | SU March |",
     "|---|---|---|---|---|---|---|---|"]
sus_f, sus_p = [], []
if final_b and final_o and paper_b and paper_o:
    for t in final_b:
        sf = final_o[t] / final_b[t]; sp = paper_o[t] / paper_b[t]; sm = march_o[t] / march[t]
        sus_f.append(sf); sus_p.append(sp)
        L.append(f"| {t} | {final_b[t]:.0f} | {final_o[t]:.0f} | {sf:.2f} | {paper_b[t]:.0f} | {paper_o[t]:.0f} | {sp:.2f} | {sm:.2f} |")
    g = lambda xs: math.exp(sum(map(math.log, xs)) / len(xs))
    L.append(f"| **geomean** | | | **{g(sus_f):.3f}** | | | **{g(sus_p):.3f}** | **2.773** |")
open(f"{root}/baseline.md", "w").write("\n".join(L) + "\n"); print("\n".join(L))
PY2
