#!/bin/bash
# profile_callbacks.sh <app> <config> [out-dir] — where do an instrumented build's cycles actually go?
#
# The campaign established that static instrumentation counts do not predict time: configurations removing up
# to 7.8 % of memory-access sites moved no number. This measures the other side — the composition of executed
# instrumentation — by sampling cycles and attributing them to the TSan callbacks by symbol:
#
#     memory accesses   __tsan_read*, __tsan_write*, __tsan_unaligned*, __tsan_vptr*
#     shadow stack      __tsan_func_entry, __tsan_func_exit          (no analysis of ours touches these)
#     atomics           __tsan_atomic*
#     interceptors      the rest of the runtime (memcpy/strcmp wrappers, mutex, alloc)
#
# This is a COMPOSITION measurement, not a difference of means: one run per cell answers "what share of cycles
# is shadow-stack maintenance", which is why applications whose speedup intervals are too wide to resolve a
# 4 % effect (memcached 12.2 pp, MySQL 14.1 pp) are still worth profiling here.
#
# A representative invocation is profiled rather than the whole benchmark: for the servers, perf launches the
# server and a short client run drives it; for the batch workloads, perf launches the workload itself. Absolute
# times are therefore not comparable with the campaign's tables — only the composition within a run is.
set -uo pipefail
cd "$(dirname "$0")"; source ./lib.sh; source ./configs.sh

APP=${1:?app}; CFG=${2:?config}; OUT=${3:-$P5_DIR/results/profile-$(date +%F)}
mkdir -p "$OUT"; OUT=$(readlink -f "$OUT")   # the sqlite branch cd's; a relative path would escape us
CPUSET=${CPUSET:-$P5_CPUSET_DEFAULT}
FREQ=${PROF_FREQ:-999}
SECS=${PROF_SECONDS:-25}
mkdir -p "$OUT/$APP/$CFG"
D="$OUT/$APP/$CFG"; DATA="$D/perf.data"
# Provenance gate, the same rule bench_one.sh enforces. The yield stage rebuilt several canonical directories,
# so an unpinned lookup silently returns a binary from a different compiler: redis-tsan and ffmpeg-tsan both
# stamp d98873cda906 today, not the campaign's d3bf9f8c39fe. Refuse rather than profile the wrong build.
[ -n "${P5_HASH:-}" ] || { echo "P5_HASH must be set (which compiler are we profiling?)" >&2; exit 1; }
BIN=$(p5_binary "$APP" "$CFG") || { echo "no binary for $APP/$CFG" >&2; exit 1; }
[ -x "$BIN" ] || { echo "not executable: $BIN" >&2; exit 1; }
want=${P5_HASH:0:12}
have=$(grep -m1 '^compiler_head:' "$(dirname "$BIN")/build_info.txt" 2>/dev/null | awk '{print substr($2,1,12)}')
[ -z "$have" ] && have=$(grep -m1 '^compiler_head:' "$(dirname "$(dirname "$BIN")")/build_info.txt" 2>/dev/null | awk '{print substr($2,1,12)}')
[ "$have" = "$want" ] || { echo "STALE BINARY for $APP/$CFG: $BIN stamps '${have:-none}', wanted $want" >&2; exit 1; }
APPDIR=$(p5_app_dir "$APP")
p5_log "profile $APP/$CFG -> $D  (binary $BIN)"

# Two modes over one set of workload definitions, so the cycle profile and the counter run cannot drift apart
# in what they actually execute. MODE=perf samples cycles; MODE=counters runs the same workload on the
# access-stats runtime and leaves the counter files behind. In counters mode nothing wraps the command.
MODE=${PROF_MODE:-perf}
RUN() { if [ ${#PERF[@]} -gt 0 ]; then "${PERF[@]}" "$@"; else "$@"; fi; }
# Stop a backgrounded workload and wait for perf to finish writing. $1 is perf's own pid in perf mode (or the
# workload's in counters mode); killing its child stops the server, and waiting on $1 guarantees the file is
# complete before anything reads it.
stop_and_flush() {
  pkill -TERM -P "$1" 2>/dev/null; sleep 2
  kill -TERM "$1" 2>/dev/null; wait "$1" 2>/dev/null
  for _ in $(seq 1 30); do kill -0 "$1" 2>/dev/null || break; sleep 1; done
}
PERF=(perf record -q -e cycles:u -F "$FREQ" --no-buildid-cache -o "$DATA" --)
if [ "$MODE" = counters ]; then
  PERF=()
  rm -f "$D"/astats.*
  export TSAN_OPTIONS="${TSAN_OPTIONS:-} access_stats_path=$D/astats print_access_stats=1"
fi

case "$APP" in
  memcached)
    (echo > /dev/tcp/127.0.0.1/7777) 2>/dev/null && { echo "port 7777 busy" >&2; exit 1; }
    "${PERF[@]}" taskset -c "$CPUSET" "$BIN" -c 4096 -t "${MC_THREADS:-24}" -p 7777 -U 0 > "$D/server.out" 2>&1 &
    perfpid=$!
    for i in $(seq 1 60); do (echo > /dev/tcp/127.0.0.1/7777) 2>/dev/null && break; sleep 1; done; sleep 1
    taskset -c "$CPUSET" "$APPDIR/memtier_benchmark-2.1.1/memtier_benchmark" --hide-histogram \
      -t 10 -p 7777 -x 1 --requests 40000 --pipeline 16 -P memcache_text --random-data > "$D/client.txt" 2>&1
    stop_and_flush "$perfpid"
    ;;
  redis)
    (echo > /dev/tcp/127.0.0.1/6379) 2>/dev/null && { echo "port 6379 busy" >&2; exit 1; }
    "${PERF[@]}" taskset -c "$CPUSET" "$BIN" --save '' --appendonly no --port 6379 > "$D/server.out" 2>&1 &
    perfpid=$!
    for i in $(seq 1 60); do (echo > /dev/tcp/127.0.0.1/6379) 2>/dev/null && break; sleep 1; done; sleep 1
    taskset -c "$CPUSET" "$APPDIR/redis-polygon/redis-benchmark/src/redis-benchmark" -p 6379 -n 200000 -c 50 -P 16 \
      -t set,get,incr,lpush,lrange_100 > "$D/client.txt" 2>&1
    stop_and_flush "$perfpid"
    ;;
  sqlite)
    # SQLITE_SUBTEST selects which of threadtest3's seven subtests to profile. Defaults to walthread1, which
    # is what the campaign profile used — but a single subtest cannot answer whether the shadow-stack share
    # varies *within* the application, which is the within-application form of the ordering test.
    rm -f "$D"/test.db*; ( cd "$D" && RUN taskset -c "$CPUSET" "$BIN" "${SQLITE_SUBTEST:-walthread1}" ) > "$D/run.log" 2>&1
    ;;
  ffmpeg)
    V=${FF_TEST_VIDEO:-$APPDIR/input/WatchingEyeTexture.mkv}
    [ -f "$V" ] || V=$(find "$APPDIR" -maxdepth 2 -name '*.mp4' -o -maxdepth 2 -name '*.mkv' 2>/dev/null | head -1)
    [ -f "$V" ] || { echo "no test video under $APPDIR" >&2; exit 1; }
    export LD_LIBRARY_PATH="$(dirname "$(dirname "$BIN")")/lib:${LD_LIBRARY_PATH:-}"   # bench_ffmpeg_all.sh:108
    RUN taskset -c "$CPUSET" "$BIN" -hide_banner -i "$V" -threads 4 -y -c:v libx264 -preset ultrafast \
      -t 20 -loglevel error /dev/shm/prof-out.mp4 > "$D/run.log" 2>&1
    ;;
  mysql)
    # The server is started inside run-one.sh, so attach by pid once it is up. Two traps here, both of which
    # bit on the first sweep: a mysqld left over from the previous cell is still dying when this one starts, and
    # `pgrep | head -1` returns that older pid — perf then attaches to a process that exits immediately and the
    # cell yields no samples while its run log looks perfectly healthy. And the harness exports its own
    # TSAN_OPTIONS (callmysql-export-main-vars.sh:53), so counter settings must go through TSAN_OPTIONS_OVERRIDE.
    for _ in $(seq 1 60); do pgrep -x mysqld >/dev/null || break; pkill -x mysqld 2>/dev/null; sleep 1; done
    pgrep -x mysqld >/dev/null && { echo "a mysqld from an earlier cell will not die; refusing" >&2; exit 1; }
    [ "$MODE" = counters ] && export TSAN_OPTIONS_OVERRIDE="report_bugs=0 verbosity=0 access_stats_path=$D/astats print_access_stats=1"
    ( cd "$APPDIR/benchmysql" && taskset -c "$CPUSET" ./run-one.sh "mysql-$(p5_base "$CFG")$(p5_tag "$CFG")" "$D/bench" ) > "$D/run.log" 2>&1 &
    legpid=$!
    mpid=""
    for i in $(seq 1 120); do mpid=$(pgrep -x mysqld | tail -1); [ -n "$mpid" ] && break; sleep 1; done
    [ -n "$mpid" ] || { echo "mysqld did not start" >&2; kill "$legpid" 2>/dev/null; exit 1; }
    sleep 20                                        # let the leg get past init into the measured section
    kill -0 "$mpid" 2>/dev/null || { echo "mysqld $mpid gone before profiling; refusing" >&2; kill "$legpid" 2>/dev/null; exit 1; }
    if [ "$MODE" = perf ]; then
      perf record -q -e cycles:u -F "$FREQ" --no-buildid-cache -o "$DATA" -p "$mpid" -- sleep "$SECS"
    else
      sleep "$SECS"
    fi
    kill -TERM "$legpid" 2>/dev/null; wait "$legpid" 2>/dev/null
    pkill -x mysqld 2>/dev/null
    for _ in $(seq 1 60); do pgrep -x mysqld >/dev/null || break; sleep 1; done   # do not leave one dying for the next cell
    ;;
  *) echo "unknown app $APP" >&2; exit 1;;
esac

if [ "$MODE" = counters ]; then
  # A run that produced no file is discarded, never recorded as a zero: a missing file means the process never
  # reached a dump, which is not the same statement as "these counters are zero".
  n=$(ls "$D"/astats.* 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] || { echo "no counter files for $APP/$CFG — discarding, not recording a zero" >&2; exit 1; }
  python3 ./counters_read.py "$D" "$APP" "$CFG" > "$D/summary.json"
else
  [ -s "$DATA" ] || { echo "no samples captured for $APP/$CFG" >&2; exit 1; }
  # A workload that failed to start still yields a perf.data and a plausible-looking composition — the redis
  # smoke run produced 34 % "in TSan" from 84 samples of an idle server whose client could not be executed.
  # Require enough samples that the run demonstrably did work.
  nsamp=$(perf script -i "$DATA" 2>/dev/null | wc -l)
  [ "$nsamp" -ge "${PROF_MIN_SAMPLES:-2000}" ] || {
    echo "only $nsamp samples for $APP/$CFG (need ${PROF_MIN_SAMPLES:-2000}) — workload did not run; discarding" >&2
    exit 1; }
  perf report -i "$DATA" --stdio --sort symbol --percent-limit 0 -q 2>/dev/null > "$D/report.txt"
  python3 ./profile_summarize.py "$D/report.txt" "$APP" "$CFG" > "$D/summary.json"
fi
cat "$D/summary.json"
