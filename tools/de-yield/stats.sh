#!/bin/bash
# stats.sh — LLVM STATISTIC counters of the TSan pass on sql/sqlite/build/sqlite3.c.
# Usage: ./stats.sh <tag> <clang> [extra -mllvm flags...]  -> stats/sqlite3c.<tag>.txt
# Flags match build_sqlite_test.sh (-g -O2 -fno-omit-frame-pointer -fsanitize=thread -DSQLITE_THREADSAFE=1).
set -euo pipefail
cd "$(dirname "$0")"
TAG=$1; C=$2; shift 2
SRC=../../sql/sqlite/build/sqlite3.c
[ -f "$SRC" ] || { echo "missing $SRC (run sql/sqlite/build_sqlite_test.sh once)"; exit 1; }
mkdir -p stats
"$C" -g -O2 -fno-omit-frame-pointer -fsanitize=thread -DSQLITE_THREADSAFE=1 -mllvm -stats "$@" \
  -c "$SRC" -o /dev/null 2>&1 | grep -E "^ +[0-9]+ tsan |Using .* for Module" > "stats/sqlite3c.$TAG.txt"
cat "stats/sqlite3c.$TAG.txt"
