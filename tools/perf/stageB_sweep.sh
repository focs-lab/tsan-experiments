#!/bin/bash
# stageB_sweep.sh <hash> — the Stage B measurement on one frozen copy, per the README's "Stage B decisions":
#   thread-policy pilot (memcached, MySQL: stock vs sound under the pinned-CPU rule and the paper's nproc rule),
#   then the full configuration set per application, one benchmark at a time under the lock, run-major,
#   N = 10 for memcached, N = 5 elsewhere, MySQL sysbench 180 s, FFmpeg at -threads 4.
# The pilot's outcome is *reported*, not auto-applied: the sweep runs the pinned rule (the README's default);
# if the pilot shows the paper rule yielding materially larger speedups, a second pass with THREAD_POLICY=paper
# is run for that application (memcached/MySQL only) and both are reported.
# Env: THREAD_POLICY=pinned|paper (default pinned), SKIP_PILOT=1, APPS="..." (default all five), N_MEMCACHED, N_DEFAULT.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh; source ./configs.sh
HASH=${1:?}; OUT="$P5_DIR/results/stageB-$HASH"; mkdir -p "$OUT"; export P5_OUT="$OUT"
APPS=${APPS:-"memcached sqlite redis ffmpeg mysql"}; N_DEFAULT=${N_DEFAULT:-5}; N_MEMCACHED=${N_MEMCACHED:-10}
export MYSQL_SECONDS=${MYSQL_SECONDS:-180} FF_THREADS=${FF_THREADS:-4}
case "${THREAD_POLICY:-pinned}" in paper) export MC_THREADS=112 MYSQL_THREADS=84;; pinned) unset MC_THREADS MYSQL_THREADS;; esac
p5_log "Stage B sweep on $HASH: apps='$APPS' policy=${THREAD_POLICY:-pinned} N=$N_DEFAULT (memcached $N_MEMCACHED)"
[ "${SKIP_PILOT:-0}" = 1 ] || { p5_log "thread-policy pilot"; ./stageB_thread_pilot.sh "$HASH" 3 > "$OUT/thread_pilot.log" 2>&1; cp "$OUT-threadpilot/thread_pilot.md" "$OUT/thread_pilot.md" 2>/dev/null; }
# Announced gap for the compiler lane's ~30 min of many-core work (second stage-b copy: build + check-tsan).
# The sweep resumes when results/stageB-<hash>/RESUME exists (created by hand after their "gap done").
echo "STAGE-B-PILOT DONE $(date -Iseconds)" >> "$OUT/pipeline.log"
if [ "${GAP_AFTER_PILOT:-1}" = 1 ]; then p5_log "gap after the pilot: waiting for $OUT/RESUME"; until [ -f "$OUT/RESUME" ]; do sleep 60; done; p5_log "resuming"; fi
for app in $APPS; do
  n=$N_DEFAULT; [ $app = memcached ] && n=$N_MEMCACHED
  cfgs=$(p5_configs_for "$app" "$P5_ALL")
  p5_log "Stage B: $app N=$n configs: $cfgs"
  ./run.sh "$app" "$HASH" "$n" --configs "$cfgs" > "$OUT/run-$app${THREAD_POLICY:+-$THREAD_POLICY}.log" 2>&1 || p5_log "run.sh $app exited non-zero"
  python3 aggregate.py "$OUT" --app "$app" > /dev/null 2>&1
done
python3 aggregate.py "$OUT" > /dev/null 2>&1
echo "STAGE-B-SWEEP DONE $HASH policy=${THREAD_POLICY:-pinned} $(date -Iseconds)" >> "$OUT/pipeline.log"
p5_log "Stage B sweep on $HASH done"
