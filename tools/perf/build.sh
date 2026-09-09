#!/bin/bash
# build.sh — build the P5 configurations of one application from a frozen compiler copy.
# Usage: ./build.sh <app> <hash> [cfg ...]            (default: Stage A set for the app; see configs.sh)
#   env: P5_OUT (results root; default results/<date>-<hash>), NPROC_<APP> (jobs), P5_SKIP_EXISTING=1
# Builds run in user.slice under nice/ionice, pause while a foreign `bench-*` unit is active, and write
# <out>/build/<app>-<cfg>.log, <out>/static-counts.csv and a build_info.txt stamp check.
set -uo pipefail
cd "$(dirname "$0")"; source ./lib.sh; source ./configs.sh
APP=${1:?app}; HASH=${2:?hash}; shift 2
# An explicit list is filtered through p5_configs_for too: a -wp/-tfn row handed to an application without a
# generator (FFmpeg, MySQL) made gen_summaries fail and build.sh exit without its completion marker (2026-09-05).
CFGS=$(p5_configs_for "$APP" "${*:-$P5_STAGE_A}")
[ "$(echo "${*:-}" | wc -w)" -eq "$(echo "$CFGS" | wc -w)" ] || p5_log "note: dropped rows not applicable to $APP from '${*:-}'"
ROOT=$(p5_compiler_root "$HASH") || exit 1
OUT="${P5_OUT:-$P5_DIR/results/$(date +%F)-$HASH}"; mkdir -p "$OUT/build"
export LLVM_TSAN_ROOT="$ROOT" BUILD_SCRATCH="$P5_SCRATCH"
mkdir -p "$P5_SCRATCH" "$P5_INSTALL_ROOT"
APPDIR=$(p5_app_dir "$APP")
jobs_var="NPROC_$(echo "$APP" | tr a-z A-Z)"; JOBS="${!jobs_var:-}"
case "$APP" in mysql) JOBS=${JOBS:-56};; ffmpeg) JOBS=${JOBS:-32};; *) JOBS=${JOBS:-8};; esac
NICE="nice -n 10 ionice -c2 -n7"
# Every build runs in its own memory-capped user scope (machine rule agreed 2026-09-07 after the 5 Sep outage:
# heavy non-container work gets an explicit MemoryMax so a runaway fails fast instead of stalling the host; it
# lands in user.slice/…/app.slice, needs no sudo and touches nobody's CPU mask — unlike `bench`, which confines
# every session to 8 CPUs). Measurements are NOT capped: TSan shadow memory can reach tens of GB and a cap
# would abort a run mid-measurement; they are pinned and record the outside-CPU busy share instead.
build_scope() {  # <app> -> systemd-run prefix with a per-application cap, or nothing if systemd-run is unusable
  # Caps must bind below user.slice's shared MemoryHigh (110 GiB for every account together, no swap; crossing
# it stalls every session — diag, 2026-09-07): MySQL 48G (56 jobs; the largest single compile is 3.4 GB),
# FFmpeg 24G, others 8G, and MySQL is launched on its own, so the concurrent total stays well under the
# 50 GiB budget agreed with tsan-dev.
  local cap; case "$1" in mysql) cap=${P5_BUILD_MEM_MYSQL:-48G};; ffmpeg) cap=${P5_BUILD_MEM_FFMPEG:-24G};; *) cap=${P5_BUILD_MEM:-8G};; esac
  command -v systemd-run >/dev/null && systemd-run --user --scope --quiet -p MemoryMax=1M -- true 2>/dev/null && echo "systemd-run --user --scope --quiet -p MemoryMax=$cap --"
}
wait_no_foreign_bench() { while p5_bench_active; do p5_log "a bench-* unit is active (we would be on 8 CPUs); waiting 5 min"; sleep 300; done; }
summaries_dir() { echo "$APPDIR/summaries-$HASH"; }
ensure_summaries() {
  [ -s "$(summaries_dir)/st_summary.txt" ] && grep -q "tsan-summary-id: $HASH" "$(summaries_dir)/st_summary.txt" && return 0
  p5_log "generating whole-program summaries for $APP ($HASH)"
  ( cd "$APPDIR" && SUMMARY_ID="$HASH" ./gen_summaries.sh "$(summaries_dir)" ) > "$OUT/build/$APP-summaries.log" 2>&1 || p5_die "gen_summaries failed for $APP (see $OUT/build/$APP-summaries.log)"
}
build_one() {  # cfg
  local cfg=$1 base tag log rc bin stamp
  base=$(p5_base "$cfg"); tag=$(p5_tag "$cfg"); log="$OUT/build/$APP-$cfg.log"
  bin=$(p5_binary "$APP" "$cfg")
  if [ "${P5_SKIP_EXISTING:-0}" = 1 ] && [ -x "$bin" ] && [ "$(p5_stamp_of_dir "$(p5_build_dir "$APP" "$cfg")")" = "$HASH" ]; then
    p5_log "skip $APP $cfg (already built with $HASH)"; return 0; fi
  local env=(USE_SUMMARIES=0 NPROC="$JOBS")
  if [ -n "$tag" ]; then ensure_summaries; env=(USE_SUMMARIES=1 SUMMARIES_DIR="$(summaries_dir)" BUILD_TAG="$tag" NPROC="$JOBS"); fi
  wait_no_foreign_bench
  p5_log "build $APP $cfg (jobs $JOBS) -> $log"
  local t0=$SECONDS
  case "$APP" in
    memcached) ( cd "$APPDIR" && env "${env[@]}" $(build_scope memcached) $NICE ./build_memcached.sh "$base" ) > "$log" 2>&1; rc=$?;;
    redis)     ( cd "$APPDIR" && env "${env[@]}" BUILD_OPTIONS="$(p5_redis_name "$cfg")" $(build_scope redis) $NICE taskset -c 4-$((3+JOBS)) ./redis.sh --compile-only ) > "$log" 2>&1; rc=$?;;
    sqlite)    ( cd "$APPDIR" && env "${env[@]}" $(build_scope sqlite) $NICE ./build_sqlite_test.sh "$base" ) > "$log" 2>&1; rc=$?;;
    mysql)     ( cd "$APPDIR" && env "${env[@]}" INSTALL_ROOT="$P5_INSTALL_ROOT/mysql" $(build_scope mysql) $NICE ./build_mysql.sh "$base" ) > "$log" 2>&1; rc=$?;;
    ffmpeg)    ( cd "$APPDIR" && env "${env[@]}" INSTALL_ROOT="$P5_INSTALL_ROOT/ffmpeg" $(build_scope ffmpeg) $NICE ./build_ffmpeg.sh "$base" ) > "$log" 2>&1; rc=$?;;
  esac
  local dt=$((SECONDS - t0))
  [ $rc = 0 ] && [ -x "$bin" ] || { p5_log "BUILD FAILED $APP $cfg rc=$rc (${dt}s) see $log"; echo "$APP,$cfg,FAILED,$rc,$dt" >> "$OUT/build/builds.csv"; return 1; }
  stamp=$(p5_stamp_of_dir "$(p5_build_dir "$APP" "$cfg")")
  [ "$stamp" = "$HASH" ] || [ "$cfg" = orig ] || { p5_log "STAMP MISMATCH $APP $cfg: build_info says '$stamp'"; return 1; }
  local sites total
  read -r sites total <<< "$(p5_static_count "$APP" "$bin")"
  echo "$APP,$cfg,$HASH,$sites,$total,$(p5_sha256 "$bin"),$dt" >> "$OUT/static-counts.csv"
  echo "$APP,$cfg,ok,0,$dt" >> "$OUT/build/builds.csv"
  p5_log "built $APP $cfg in ${dt}s: $sites memory-access sites ($total tsan calls)"
}
# builds of different apps run concurrently (shared lock); a benchmark holds the lock exclusively, so no
# build starts while one of our benchmarks runs and no benchmark starts while a build runs
exec 9>"$P5_LOCK"; flock -s 9
# Machine-wide job lock (rule agreed across lanes, 2026-09-07, revised the same afternoon): /home/alexey/bin/logs/machine-memory.lock
# (the name is historical; never recreate the file). EXCLUSIVE for any job that (a) is capped >= 20 GiB, or
# (b) runs >= 8 sustained cores, or (c) is a timing measurement; shared or unlocked otherwise. Every build of
# this lane is (b) (jobs 8..56), so all builds are exclusive; measurements (bench_one.sh) are (c), per run.
# A sidecar machine-memory.lock.holder names the holder so a waiter can see what it is queueing behind.
# the agreed canonical path (not /tmp, which tmpfiles.d empties at boot)
MEMLOCK="${MACHINE_MEMLOCK:-/home/alexey/bin/logs/machine-memory.lock}"; [ -e "$MEMLOCK" ] || { : > "$MEMLOCK"; chmod 666 "$MEMLOCK" 2>/dev/null; }
exec 8>"$MEMLOCK"; p5_log "waiting for the machine job lock (exclusive: build $APP, jobs $JOBS)"; flock -x 8
printf 'lane=tsan-exp\npid=%s\nmode=exclusive\nreason=build %s (%s), jobs %s >= 8 cores\nstart=%s\nexpected_minutes=%s\ncpus=%s\nwhy=P5 build\n' "$$" "$APP" "$HASH" "$JOBS" "$(date -Iseconds)" "$([ "$APP" = mysql ] && echo 120 || echo 20)" "4-$((3+JOBS))" > "$MEMLOCK.holder" 2>/dev/null; chmod 666 "$MEMLOCK.holder" 2>/dev/null
trap 'rm -f "$MEMLOCK.holder" 2>/dev/null' EXIT
[ -f "$OUT/static-counts.csv" ] || echo "app,config,hash,memory_access_sites,tsan_calls_total,sha256,build_seconds" > "$OUT/static-counts.csv"
fail=0; for c in $CFGS; do build_one "$c" || fail=1; done
p5_log "builds of $APP done (fail=$fail); static counts in $OUT/static-counts.csv"; exit $fail
