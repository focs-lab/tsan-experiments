#!/bin/bash
# Lock-ownership soundness probes: build each lo_*.c with stock TSan and with
# -mllvm -tsan-use-lock-ownership, count the __tsan_read/write calls left in the touch*()
# functions, run the binary 5 times and count runs that report the race on G.
# Usage: [LLVM_TSAN_ROOT=<llvm/build>] ./lo_probes_run.sh   -> table on stdout, files in lo-probes-out/
set -uo pipefail
cd "$(dirname "$0")"
source ../tsan_compiler.sh
OUT=lo-probes-out; mkdir -p $OUT
echo "compiler: $TSAN_CC ($("$TSAN_CC" --version | head -1))"
printf "%-28s %-22s %-22s\n" probe "stock: instr/reports" "LO: instr/reports"
for src in lo_*.c; do
  p=${src%.c}; row="$p"
  for mode in stock lo; do
    flags="-O1 -g -fsanitize=thread"; [ $mode = lo ] && flags="$flags -mllvm -tsan-use-lock-ownership"
    "$TSAN_CC" $flags -S -emit-llvm -o $OUT/$p.$mode.ll $src 2>/dev/null
    "$TSAN_CC" $flags -o $OUT/$p.$mode $src 2>/dev/null || { row="$row  build-failed"; continue; }
    n=$(awk '/^define.*@touch/,/^}/' $OUT/$p.$mode.ll | grep -c "@__tsan_\(read\|write\)")
    # (no pipeline into grep -q: with pipefail its early exit turns every run into "no report")
    r=0; for i in 1 2 3 4 5; do o=$(TSAN_OPTIONS="exitcode=0" $OUT/$p.$mode 2>&1); case "$o" in *"WARNING: ThreadSanitizer: data race"*) r=$((r+1));; esac; done
    row="$row $(printf '%-22s' "$n / $r of 5")"
  done
  echo "$row"
done
