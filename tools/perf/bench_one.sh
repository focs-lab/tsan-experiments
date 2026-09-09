#!/bin/bash
# bench_one.sh — one repetition of one application's paper workload for one configuration.
# Usage: ./bench_one.sh <app> <cfg> <run> <out-root> [cpuset]
# Writes <out-root>/<app>/<cfg>/run<k>/{raw artefact(s), meta.json, cmd.log}. The workload is pinned with
# taskset to the cpuset (default lib.sh P5_CPUSET_DEFAULT); nproc inside it = the pinned CPU count.
set -uo pipefail
cd "$(dirname "$0")"; source ./lib.sh; source ./configs.sh
APP=${1:?}; CFG=${2:?}; RUN=${3:?}; OUTROOT=${4:?}; CPUSET=${5:-$P5_CPUSET_DEFAULT}
BASE=$(p5_base "$CFG"); TAG=$(p5_tag "$CFG"); APPDIR=$(p5_app_dir "$APP"); BIN=$(p5_binary "$APP" "$CFG")
[ -x "$BIN" ] || p5_die "no binary for $APP $CFG: $BIN"
if [ -n "${P5_HASH:-}" ]; then   # provenance gate: the binary must carry the hash this sweep is about
  bstamp=$(grep -m1 "^compiler_head:" "$(p5_build_dir "$APP" "$CFG")/build_info.txt" 2>/dev/null | awk '{print substr($2,1,12)}')
  [ "$bstamp" = "${P5_HASH:0:12}" ] || p5_die "STALE BINARY for $APP $CFG: build_info compiler_head=${bstamp:-none}, sweep hash=$P5_HASH (rebuild with build.sh)"
fi
D="$OUTROOT/$APP/$CFG/run$RUN"; mkdir -p "$D"; LOG="$D/cmd.log"
NCPU=$(taskset -c "$CPUSET" nproc)
export TSAN_OPTIONS="${TSAN_OPTIONS:-report_bugs=0}"
TS() { taskset -c "$CPUSET" "$@"; }
# The machine lock, the sidecar and the 32G memory scope are taken by run.sh's machine-lock wrapper around this
# script (one process per run); nothing here locks.
read -r busy0 idle0 <<< "$(p5_cpu_snapshot)"; read -r in0 out0 nin nout <<< "$(python3 ./cpu_snapshot.py "$CPUSET")"
load0=$(p5_loadavg); mhz0="$(p5_cpu_mhz 4)/$(p5_cpu_mhz 60)"; regime=$(p5_regime); t0=$(date +%s.%N)
EXTRA_TICKS=0   # CPU time of ours that /usr/bin/time cannot see (a server started outside the timed region)
TIMEF=/usr/bin/time; OURS="$D/ours.time"
rc=0
case "$APP" in
  memcached)
    # paper workload: server -c 4096 -t <cpus> -p 7777; memtier -t 10 -x 5 --pipeline 16 -P memcache_text --random-data
    (echo > /dev/tcp/127.0.0.1/7777) 2>/dev/null && p5_die "port 7777 busy"
    taskset -c "$CPUSET" "$BIN" -c 4096 -t "${MC_THREADS:-$((NCPU / 2))}" -p 7777 -U 0 > "$D/server.out" 2>&1 &   # MC_THREADS: thread-policy pilot
    spid=$!
    for i in $(seq 1 60); do (echo > /dev/tcp/127.0.0.1/7777) 2>/dev/null && break; sleep 1; done; sleep 1
    $TIMEF -f "%U %S %M" -o "$OURS" taskset -c "$CPUSET" "$APPDIR/memtier_benchmark-2.1.1/memtier_benchmark" --hide-histogram \
      -t 10 -p 7777 -x "${NTESTS:-5}" --requests "${MC_REQUESTS:-100000}" --pipeline 16 -P memcache_text --random-data > "$D/memtier.txt" 2> "$LOG"; rc=$?
    # MC_REQUESTS: the paper's 10 000 requests per client (5 M per iteration) made an iteration last ~1 s on the
    # counters-off runtime (2 M ops/s) and ~1 s on native, and memtier's per-iteration ops/s is computed from
    # 1-second progress samples: single iterations reported 57 M ops/s on native and 3.5 M on tsan-dom, i.e.
    # garbage. 100 000 per client (50 M per iteration, 10-25 s) makes memtier's aggregate meaningful again.
    # Stage A ran with 10 000; Stage B from 2026-09-07 with 100 000.
    grep VmHWM /proc/$spid/status 2>/dev/null > "$D/server.rss"      # peak RSS of the server before it exits
    # the server runs outside the timed region: add its ticks to ours, else its 48 threads look like foreign load
    EXTRA_TICKS=$(awk '{print $14+$15+$16+$17}' /proc/$spid/stat 2>/dev/null || echo 0)
    kill -TERM "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
    for i in $(seq 1 30); do (echo > /dev/tcp/127.0.0.1/7777) 2>/dev/null || break; sleep 1; done
    ;;
  redis)
    ( cd "$APPDIR" && REDIS_ORIG_MULT=1 BUILD_OPTIONS="$(p5_redis_name "$CFG")" BUILD_TAG="$TAG" $TIMEF -f "%U %S %M" -o "$OURS" taskset -c "$CPUSET" ./redis.sh --test-only ) > "$LOG" 2>&1; rc=$?
    cp "$APPDIR/redis-polygon/__results_redis__/results.txt" "$D/results.txt" 2>/dev/null || rc=1
    ;;
  sqlite)
    ( cd "$APPDIR" && $TIMEF -f "%U %S %M" -o "$OURS" taskset -c "$CPUSET" ./run_sqlite_test.sh "$BASE$TAG" ) > "$LOG" 2>&1; rc=$?
    cp "$APPDIR/results/$BASE$TAG.log" "$D/threadtest3.log" 2>/dev/null || rc=1
    grep "^$BASE$TAG	" "$APPDIR/results/memory.txt" 2>/dev/null | tail -1 > "$D/memory.txt"
    ;;
  mysql)
    ( cd "$APPDIR/benchmysql" && SYSBENCH_RUN_SECONDS="${MYSQL_SECONDS:-180}" SYSBENCH_RUN_THREADS="${MYSQL_THREADS:-$((NCPU / 2 * 3 / 4))}" \
        $TIMEF -f "%U %S %M" -o "$OURS" taskset -c "$CPUSET" ./run-one.sh "mysql-$BASE$TAG" "$D" ) > "$LOG" 2>&1; rc=$?
    ;;
  ffmpeg)
    # -threads goes straight to the encoder: libx265 maps it to frame threads and refuses anything above
    # X265_MAX_FRAME_THREADS (16), so a pinned-CPU-count default of 48 makes the h265 codec fail on every
    # build and vanish from the results.  The paper's runs used 4; keep that unless FF_THREADS says otherwise.
    ( cd "$APPDIR" && RUNS_COUNT=1 FF_BUILD_LIST="ffmpeg-$BASE$TAG" FFMPEG_BENCH_NPROC_COUNT="${FF_THREADS:-4}" \
        SUMMARY_CSV="$D/summary.csv" SUMMARY_JSON="$D/summary.json" \
        $TIMEF -f "%U %S %M" -o "$OURS" taskset -c "$CPUSET" ./bench_ffmpeg_all.sh ) > "$LOG" 2>&1; rc=$?
    [ -s "$D/summary.csv" ] || rc=1
    ;;
esac
t1=$(date +%s.%N); read -r busy1 idle1 <<< "$(p5_cpu_snapshot)"; read -r in1 out1 nin nout <<< "$(python3 ./cpu_snapshot.py "$CPUSET")"
load1=$(p5_loadavg)
read -r ou os om <<< "$(tail -1 "$OURS" 2>/dev/null)"
HZ=$(getconf CLK_TCK); machine_busy=$(( (busy1 - busy0) )); ours_ticks=$(python3 -c "print(int((${ou:-0}+${os:-0})*$HZ) + ${EXTRA_TICKS:-0})")
python3 - "$D" <<PY
import json, hashlib, os, sys, time
d = sys.argv[1]
bi = {}
for cand in ("$(p5_build_dir "$APP" "$CFG")/build_info.txt",):
    if os.path.exists(cand):
        bi = dict(l.split(": ",1) for l in open(cand).read().splitlines() if ": " in l)
meta = {
  "app": "$APP", "config": "$CFG", "run": $RUN, "rc": $rc,
  "binary": "$BIN", "sha256": hashlib.sha256(open("$BIN","rb").read()).hexdigest(),
  "compiler_version": bi.get("compiler_version"), "compiler_head": bi.get("compiler_head"), "flags": bi.get("flags"), "summaries": bi.get("summaries"),
  "start": $t0, "end": $t1, "seconds": round($t1 - $t0, 1),
  "cpuset": "$CPUSET", "ncpu": $NCPU, "mode": "${P5_MODE:-pinned}",
  "governor": "$(p5_governor)", "no_turbo": "$(p5_turbo)",
  "regime": "$regime", "bench_session": $(p5_bench_session), "cpu_mhz_start": "$mhz0", "cpu_mhz_end": "$(p5_cpu_mhz 4)/$(p5_cpu_mhz 60)",
  "loadavg_before": "$load0", "loadavg_after": "$load1",
  "machine_busy_ticks": $machine_busy, "ours_ticks": $ours_ticks, "extra_ticks": ${EXTRA_TICKS:-0}, "hz": $HZ,
  "inside_busy_share": round(($in1 - $in0) / max(1.0, ($t1 - $t0) * $HZ * $nin), 4),
  "outside_busy_share": round(($out1 - $out0) / max(1.0, ($t1 - $t0) * $HZ * $nout), 4),
  "n_inside": $nin, "n_outside": $nout,
  "foreign_ticks": max(0, $machine_busy - $ours_ticks),
  "foreign_cpu_share": round(max(0, $machine_busy - $ours_ticks) / max(1.0, ($t1 - $t0) * $HZ * $(nproc)), 4),
  "tsan_options": "$TSAN_OPTIONS", "max_rss_kb": ${om:-0},
  "threads_setting": "${MC_THREADS:-}${MYSQL_THREADS:-}${FF_THREADS:-}",
}
json.dump(meta, open(os.path.join(d, "meta.json"), "w"), indent=1)
print(f"{meta['app']} {meta['config']} run{meta['run']} rc={meta['rc']} {meta['seconds']}s "
      f"outside_busy={meta['outside_busy_share']} inside_busy={meta['inside_busy_share']} foreign_cpu_share={meta['foreign_cpu_share']}")
PY
exit $rc
