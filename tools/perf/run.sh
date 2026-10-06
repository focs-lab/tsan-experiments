#!/bin/bash
# run.sh — N repetitions of one application's workload over its P5 configurations (run-major order).
# Usage: ./run.sh <app> <hash> [N] [--configs "c1 c2"] [--cpuset 4-27,60-83] [--in-bench] [--pair]
#   env: P5_OUT (results root), MYSQL_SECONDS, NTESTS, P5_FOREIGN_MAX (disturbed threshold, default 0.10)
# Pinned mode by default; if another user's bench-* unit is active and --in-bench is not set, defers to
# bench_session.sh (a bench reservation driven through tmux). Resumable: existing run<k>/meta.json are kept.
set -uo pipefail
cd "$(dirname "$0")"; source ./lib.sh; source ./configs.sh
APP=${1:?}; HASH=${2:?}; shift 2; N=5; CFGS=""; CPUSET="$P5_CPUSET_DEFAULT"; INBENCH=0; PAIR=0; WARMUP=0
while [ $# -gt 0 ]; do case "$1" in
  --configs) CFGS="$2"; shift 2;; --cpuset) CPUSET="$2"; shift 2;; --in-bench) INBENCH=1; shift;; --pair) PAIR=1; shift;;
  --warmup) WARMUP="$2"; shift 2;;
  [0-9]*) N=$1; shift;; *) p5_die "unknown arg $1";; esac; done
[ -n "$CFGS" ] || CFGS=$(p5_configs_for "$APP" "$P5_STAGE_A")
OUT="${P5_OUT:-$P5_DIR/results/$(date +%F)-$HASH}"; mkdir -p "$OUT"; OUT=$(readlink -f "$OUT")
# absolute, always: the redis/sqlite/mysql/ffmpeg branches of bench_one.sh cd into the application dir, and a
# relative results path then breaks /usr/bin/time -o with exit 125 and a zero-length run. The campaign never
# hit it because its launchers passed an absolute P5_OUT; a hand-run leg with a relative one loses every run.
if [ $INBENCH = 0 ] && p5_bench_active; then
  p5_log "a foreign bench-* reservation is active: running inside our own bench reservation"
  exec ./bench_session.sh "$APP" "$HASH" "$N" --configs "$CFGS"
fi
# one benchmark at a time (two only when --pair is given after the interference pilot)
exec 9>"$P5_LOCK"; flock -x 9 || p5_die "lock"      # exclusive: no builds, no other benchmark meanwhile
# "pinned" was written whatever the cpuset held, so an UNPINNED session recorded mode "pinned" beside
# cpuset "" -- a label contradicting the field next to it, and the one a reader trusts first. Three states,
# named for what they are. (spotted in the contract smoke, 2026-09-18.)
if [ "$INBENCH" = 1 ]; then export P5_MODE=bench
elif [ -n "${CPUSET:-}" ]; then export P5_MODE=pinned
else export P5_MODE=unpinned; fi
# Rejection threshold on the busy share of the CPUs outside our pinned set. 0.15 once rejected runs that
# were merely normal (MySQL lost two of three native runs at 0.15-0.17 and reported N=1) and the default
# was raised to 0.25; the campaign then tightened it to 0.10 and retired the cells above it, which is the
# figure the documents quote. The DEFAULT had stayed at 0.25, so only the lab launchers that set the
# variable ever ran the documented gate and every evaluator silently ran a looser one. The default is now
# the campaign's, and the value in force is recorded per session below, so the two cannot drift unseen
# again. (Found on the evaluator path, 2026-09-17, the same way as the other three defects of that day.)
FMAX=${P5_FOREIGN_MAX:-0.10}
# Fast-failure stop (exit 70). FFSECS is below the shortest cell any application produces even in smoke
# mode, so only a cell that exited nonzero can match it; FFMAX is how many such cells of one configuration
# the leg tolerates before stopping.
FFSECS=${P5_FAIL_FAST_SECONDS:-5}
FFMAX=${P5_FAIL_FAST_MAX:-2}
declare -A FASTFAIL
# Inside/outside CPU counts from the same helper bench_one.sh uses, so the session and its cells cannot
# disagree about whether the gate is checkable at all.
read -r _ _ SNIN SNOUT <<< "$(python3 ./cpu_snapshot.py "$CPUSET")"
python3 - "$OUT/$APP" <<PY
import json, os, sys, subprocess, time
d=sys.argv[1]; os.makedirs(d, exist_ok=True)
json.dump({"app":"$APP","hash":"$HASH","N":$N,"configs":"$CFGS".split(),"cpuset":"$CPUSET","mode":os.environ["P5_MODE"],
  "started":time.strftime("%FT%T"),"host":os.uname().nodename,"nproc_machine":os.cpu_count(),
  # Through the shell helpers, which return empty where the file is absent (no intel_pstate on AMD hosts
  # and most VMs): an unguarded open() here raised FileNotFoundError and no session.json was written on
  # exactly the hosts evaluators have (found on the AMD run of 19 Sep 2026).
  "governor":"$(p5_governor)","no_turbo":"$(p5_turbo)",
  # The gate, recorded where a reader looks for the session's parameters rather than inferred from the
  # cells. gate_checked false means an unpinned session, where there are no outside CPUs to measure and
  # a share of 0.0 would read as a quiet machine (docs/confounds.md, "An unpinned run is not gate-checked").
  "n_inside":$SNIN,"n_outside":$SNOUT,"gate_checked":($SNOUT > 0),"foreign_max":$FMAX},
  open(os.path.join(d,"session.json"),"w"), indent=1)
PY
for c in $CFGS; do [ -x "$(p5_binary "$APP" "$c")" ] || p5_die "missing binary for $APP $c (build first)"; done
export P5_HASH="$HASH"   # bench_one.sh refuses binaries built by another compiler
bench_and_mark() {  # cfg run [suffix]
  local c=$1 run=$2 d="$OUT/$APP/$1/${P5_RUN_PREFIX:-run}$2" line
  # Common machine lock (rule of 2026-09-07): a timing measurement holds the machine memory lock
  # exclusively per run; the wrapper writes the sidecar, runs the measurement in a 32G scope pinned to the
  # bench set, and reports memory.peak. Expected minutes per application are the observed run lengths.
  mins=$(case "$APP" in mysql) echo 15;; ffmpeg) echo 8;; sqlite) echo 6;; *) echo 3;; esac)
  # The whole-machine lock is this lab's; nothing outside it has one. P5_MACHINE_LOCK names the wrapper and
  # the artifact sets it to `true`, meaning no lock is needed. Hardcoding the path made every run in the
  # container die with "No such file or directory" and be recorded as DISTURBED — a measurement that never
  # ran, filed as one that ran badly, which is the worst of the three possible outcomes.
  MLOCK="${P5_MACHINE_LOCK:-$HOME/bin/machine-lock}"
  if [ "$MLOCK" = true ] || [ ! -x "$MLOCK" ]; then
    [ "$MLOCK" = true ] || p5_log "note: no machine lock at $MLOCK; running unwrapped"
    line=$(./bench_one.sh "$APP" "$c" "$run" "$OUT" "$CPUSET" 2>&1 | tail -1)
  else
    line=$("$MLOCK" --lane "${P5_LANE:-bench}" --measure --mem "${P5_MEAS_MEM:-32G}" --minutes "$mins" --cpus bench \
             --why "$APP $c run$run ($HASH)" -- ./bench_one.sh "$APP" "$c" "$run" "$OUT" "$CPUSET" 2>&1 | grep -v '^machine-lock:' | tail -1)
  fi
  p5_log "$line"; echo "$line${3:-}" >> "$OUT/$APP/runs.log"
  [ -f "$d/meta.json" ] || { mkdir -p "$d"; printf '{"app":"%s","config":"%s","run":%s,"rc":1,"seconds":0,"foreign_cpu_share":0,"error":"%s"}\n' "$APP" "$c" "$run" "${line//\"/}" > "$d/meta.json"; }
  python3 ./meta_tool.py mark "$d/meta.json" "$FMAX"
  # A LEG MUST NOT SPEND ITS WHOLE MATRIX DISCOVERING ONE BROKEN PATH. When a configuration's cells exit
  # nonzero in less time than any real workload takes, nothing is being measured and repeating it only
  # buries the reason: the MySQL leg of 22 Sep 2026 retired 30 cells in 40 seconds and ended in a NO DATA
  # table, with the cause -- one missing directory -- visible in the first cell and in every one after it.
  # Two such cells of the SAME configuration stop the leg with the reason quoted, which costs one wasted
  # cell instead of a matrix. A healthy cell of that configuration resets the count, so a single transient
  # failure does not end a long leg.
  if python3 ./meta_tool.py is-fast-failure "$d/meta.json" "$FFSECS"; then
    FASTFAIL["$c"]=$(( ${FASTFAIL["$c"]:-0} + 1 ))
    if [ "${FASTFAIL[$c]}" -ge "$FFMAX" ]; then
      p5_log "STOPPING THE LEG: $APP/$c produced ${FASTFAIL[$c]} cells that exited nonzero in under ${FFSECS}s."
      p5_log "  reason from the last cell: $(python3 ./meta_tool.py reason "$d/meta.json")"
      p5_log "  cell: $d"
      p5_log "  Nothing was measured, so no table is written for this leg. Fix the cause and re-run;"
      p5_log "  completed cells are kept and skipped (is-done), so the leg resumes where it stopped."
      echo "STOPPED $APP $c (fast failures)" >> "$OUT/$APP/runs.log"
      exit 70
    fi
  else
    FASTFAIL["$c"]=0
  fi
}
# Discarded warm-up, before the measured runs and once per configuration. The campaign reports STEADY-STATE
# performance (docs/campaign-parameters.md): the warm-up builds SQLite's database and leaves it, warms FFmpeg's
# input into page cache, warms the allocator and connection path for memcached and Redis, and leaves MySQL's
# server initialised with its buffer pool populated. Its numbers are never read — aggregate.py matches
# run\d+ exactly — but its state is exactly what the measured runs are supposed to start from.
for k in $(seq 1 "$WARMUP"); do
  for c in $CFGS; do
    if python3 ./meta_tool.py is-done "$OUT/$APP/$c/warmup$k/meta.json" 2>/dev/null; then continue; fi
    rm -rf "$OUT/$APP/$c/warmup$k"; P5_RUN_PREFIX=warmup bench_and_mark "$c" "$k" " (warmup, discarded)"
  done
done
for run in $(seq 1 "$N"); do
  for c in $CFGS; do
    d="$OUT/$APP/$c/run$run"
    if python3 ./meta_tool.py is-done "$d/meta.json" 2>/dev/null; then p5_log "skip $APP $c run$run (done)"; continue; fi
    rm -rf "$d"; bench_and_mark "$c" "$run"
  done
done
# re-run disturbed runs once, at the end
for run in $(seq 1 "$N"); do for c in $CFGS; do d="$OUT/$APP/$c/run$run"
  if python3 ./meta_tool.py is-disturbed "$d/meta.json"; then
    p5_log "re-running disturbed $APP $c run$run"; mv "$d" "$d.disturbed.$(date +%H%M%S)"; bench_and_mark "$c" "$run" " (rerun)"
  fi; done; done
p5_log "done: $APP N=$N -> $OUT/$APP"; echo "DONE $APP" >> "$OUT/$APP/runs.log"
