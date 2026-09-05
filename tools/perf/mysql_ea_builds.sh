#!/bin/bash
# mysql_ea_builds.sh — build the remaining escape-analysis MySQL configurations, one at a time, on the CPUs
# parked for background work (52-54,108-110; see tools/perf/ignore_cpus).  Each costs ~3 h in sql_yacc.cc alone
# on 729521af8965 (tools/notes/ea-compile-time-2026-09-04.md), so they run overnight beside the benchmarks
# instead of blocking them.  RESUME_BUILD=1 means an interruption does not pay that cost twice.
set -uo pipefail
cd /home/alexey/tsan-experiments/sql/mysql
export LLVM_TSAN_ROOT=/extra/alexey/builds/tsan-dev-729521af8965
export INSTALL_ROOT=/extra/alexey/tsan-experiments/installs
export RESUME_BUILD=1 NPROC=3
LOG=/home/alexey/tsan-experiments/tools/perf/build-mysql-ea-chain.log
# wait for the tsan-sound build already running to finish
while pgrep -f "build_mysq[l]\.sh tsan-sound" > /dev/null; do sleep 120; done
for cfg in tsan-dom-ea-lo-st-swmr tsan-dom_peeling-ea-lo-st-swmr; do
  echo "[$(date '+%F %T')] building mysql $cfg" >> "$LOG"
  taskset -c 52-54,108-110 nice -n 15 ionice -c2 -n7 ./build_mysql.sh "$cfg" >> "$LOG" 2>&1
  echo "[$(date '+%F %T')] mysql $cfg exit $?" >> "$LOG"
done
echo "[$(date '+%F %T')] MySQL EA chain done" >> "$LOG"
