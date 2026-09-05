#!/bin/bash
# run.sh — N repetitions of one application's workload over its P5 configurations (run-major order).
# Usage: ./run.sh <app> <hash> [N] [--configs "c1 c2"] [--cpuset 4-27,60-83] [--in-bench] [--pair]
#   env: P5_OUT (results root), MYSQL_SECONDS, NTESTS, P5_FOREIGN_MAX (disturbed threshold, default 0.15)
# Pinned mode by default; if another user's bench-* unit is active and --in-bench is not set, defers to
# bench_session.sh (a bench reservation driven through tmux). Resumable: existing run<k>/meta.json are kept.
set -uo pipefail
cd "$(dirname "$0")"; source ./lib.sh; source ./configs.sh
APP=${1:?}; HASH=${2:?}; shift 2; N=5; CFGS=""; CPUSET="$P5_CPUSET_DEFAULT"; INBENCH=0; PAIR=0
while [ $# -gt 0 ]; do case "$1" in
  --configs) CFGS="$2"; shift 2;; --cpuset) CPUSET="$2"; shift 2;; --in-bench) INBENCH=1; shift;; --pair) PAIR=1; shift;;
  [0-9]*) N=$1; shift;; *) p5_die "unknown arg $1";; esac; done
[ -n "$CFGS" ] || CFGS=$(p5_configs_for "$APP" "$P5_STAGE_A")
OUT="${P5_OUT:-$P5_DIR/results/$(date +%F)-$HASH}"; mkdir -p "$OUT"
if [ $INBENCH = 0 ] && p5_bench_active; then
  p5_log "a foreign bench-* reservation is active: running inside our own bench reservation"
  exec ./bench_session.sh "$APP" "$HASH" "$N" --configs "$CFGS"
fi
# one benchmark at a time (two only when --pair is given after the interference pilot)
exec 9>"$P5_LOCK"; flock -x 9 || p5_die "lock"      # exclusive: no builds, no other benchmark meanwhile
export P5_MODE=$([ $INBENCH = 1 ] && echo bench || echo pinned)
python3 - "$OUT/$APP" <<PY
import json, os, sys, subprocess, time
d=sys.argv[1]; os.makedirs(d, exist_ok=True)
json.dump({"app":"$APP","hash":"$HASH","N":$N,"configs":"$CFGS".split(),"cpuset":"$CPUSET","mode":os.environ["P5_MODE"],
  "started":time.strftime("%FT%T"),"host":os.uname().nodename,"nproc_machine":os.cpu_count(),
  "governor":open("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor").read().strip(),
  "no_turbo":open("/sys/devices/system/cpu/intel_pstate/no_turbo").read().strip()}, open(os.path.join(d,"session.json"),"w"), indent=1)
PY
for c in $CFGS; do [ -x "$(p5_binary "$APP" "$c")" ] || p5_die "missing binary for $APP $c (build first)"; done
# Rejection threshold on the busy share of the CPUs outside our pinned set. This machine carries ~0.10 of
# other people's load at rest (a dozen agent sessions), so 0.15 rejected runs that were merely normal: MySQL
# lost two of three native runs at 0.15-0.17 and reported N=1. 0.25 keeps those and still rejects a real
# second workload (the interference pilot's paired arm sat at ~0.5).
FMAX=${P5_FOREIGN_MAX:-0.25}
export P5_HASH="$HASH"   # bench_one.sh refuses binaries built by another compiler
bench_and_mark() {  # cfg run [suffix]
  local c=$1 run=$2 d="$OUT/$APP/$1/run$2" line
  line=$(./bench_one.sh "$APP" "$c" "$run" "$OUT" "$CPUSET" 2>&1 | tail -1); p5_log "$line"; echo "$line${3:-}" >> "$OUT/$APP/runs.log"
  [ -f "$d/meta.json" ] || { mkdir -p "$d"; printf '{"app":"%s","config":"%s","run":%s,"rc":1,"foreign_cpu_share":0,"error":"%s"}\n' "$APP" "$c" "$run" "${line//\"/}" > "$d/meta.json"; }
  python3 ./meta_tool.py mark "$d/meta.json" "$FMAX"
}
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
