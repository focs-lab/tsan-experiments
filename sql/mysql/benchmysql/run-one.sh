#!/bin/bash
# run-one.sh — one repetition of the paper's sysbench workload for ONE build, outputs to a chosen directory.
# The loop body of benchmarks-launch.sh (server-run, bench-init, bench-run, bench-cleanup, server-shutdown)
# without its build discovery and file naming, so a driver can repeat it N times with distinct output paths.
# Usage: ./run-one.sh <build-dir-name e.g. mysql-tsan-sound> <out-dir> [script.lua ...]
#   env: SYSBENCH_RUN_SECONDS (default 180), SYSBENCH_RUN_THREADS (default nproc*3/4), MYSQL_BUILDS_DIR (..),
#        MYSQL_DATA_DIR (/tmp/mysql-benchmarks-datadir; initialised on first use), TSAN_OPTIONS_OVERRIDE.
set -uo pipefail
cd "$(dirname "$0")"
BUILD=${1:?build dir name}; OUT=${2:?output dir}; shift 2
SCRIPTS=${*:-${MYSQL_SCRIPTS:-oltp_read_write.lua oltp_read_only.lua oltp_write_only.lua select_random_ranges.lua select_random_points.lua}}   # MYSQL_SCRIPTS (30 Sep): workload-coverage screening
export MYSQL_BUILDS_DIR="${MYSQL_BUILDS_DIR:-..}"
export SYSBENCH_SCRIPTS_DIR="${SYSBENCH_SCRIPTS_DIR:-/usr/share/sysbench}"
export MYSQL_DATA_DIR="${MYSQL_DATA_DIR:-/tmp/mysql-benchmarks-datadir}"
export MYSQL_DIR="$MYSQL_BUILDS_DIR/$BUILD/bin"
[ -x "$MYSQL_DIR/mysqld" ] || { echo "no mysqld at $MYSQL_DIR"; exit 2; }
mkdir -p "$OUT"
[ -d "$MYSQL_DATA_DIR" ] || ./server-datadir-init.sh || { echo "datadir init failed"; exit 3; }
rc_all=0
for s in $SCRIPTS; do
  export SYSBENCH_SCRIPT_FILENAME="$s"
  out="$OUT/${s%.lua}.txt"
  # log_path for this workload's mysqld only, via TSAN_OPTIONS_OVERRIDE (callmysql-export-main-vars.sh rebuilds TSAN_OPTIONS from it; not exported, so no accumulation): every TSan report / CHECK / DEADLYSIGNAL stack ->
  # <run dir>/<workload>.tsan.<pid>, whatever happens to stderr
  TSAN_OPTIONS_OVERRIDE="${TSAN_OPTIONS_OVERRIDE:-report_bugs=0 verbosity=0} log_path=$OUT/${s%.lua}.tsan" ./server-run.sh || { echo "cannot start server for $BUILD" | tee -a "$out"; rc_all=1; continue; }
  ./bench-init.sh
  ./bench-run.sh > "$out"; rc=$?
  ./bench-cleanup.sh
  ./server-check-connection.sh >/dev/null 2>&1 || { echo "SERVER NOT REACHABLE before shutdown ($(date '+%F %T'))" | tee -a "$out"; rc=98; }
  ./server-shutdown.sh
  cp -f server-run.stderr.log "$OUT/${s%.lua}.server.log" 2>/dev/null   # per-workload mysqld stderr = its error log here, incl. TSan's DEADLYSIGNAL stack
  cp -f time.log "$OUT/${s%.lua}.time.log" 2>/dev/null                   # /usr/bin/time -v: mysqld's exit status or terminating signal
  for e in "$MYSQL_DATA_DIR"/*.err; do [ -f "$e" ] && cp -f "$e" "$OUT/${s%.lua}.$(basename "$e")"; done
  grep -q "Lost connection to MySQL server" "$out" && { echo "LOST CONNECTION in $s (server died?)" | tee -a "$out"; rc=97; }
  [ -f time.log ] && { grep "Maximum resident set size" time.log >> "$out"; rm -f time.log; }
  [ $rc = 0 ] || rc_all=1
  echo "$s rc=$rc"
done
exit $rc_all
