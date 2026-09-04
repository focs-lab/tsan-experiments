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
SCRIPTS=${*:-oltp_read_write.lua oltp_read_only.lua oltp_write_only.lua select_random_ranges.lua select_random_points.lua}
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
  ./server-run.sh || { echo "cannot start server for $BUILD" | tee -a "$out"; rc_all=1; continue; }
  ./bench-init.sh
  ./bench-run.sh > "$out"; rc=$?
  ./bench-cleanup.sh
  ./server-shutdown.sh
  [ -f time.log ] && { grep "Maximum resident set size" time.log >> "$out"; rm -f time.log; }
  [ $rc = 0 ] || rc_all=1
  echo "$s rc=$rc"
done
exit $rc_all
