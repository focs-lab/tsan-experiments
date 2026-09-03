#!/bin/bash
# P3 rate: per-granule eviction counters (evict_watch) on the wal-index header words of threadtest3, N runs per
# config, ASLR off (setarch -R) so the mapping address is stable; the base is read from a calibration run's report.
# Usage: ./watch_sqlite.sh <frozen llvm build dir> <hash> [N] -> results/<hash>/watch.txt
set -uo pipefail; cd "$(dirname "$0")"
F=${1:?}; HASH=${2:?}; N=${3:-10}; export LLVM_TSAN_ROOT=$F
VER=$("$F/bin/clang" --version | head -1); case "$VER" in *"$HASH"*) ;; *) echo "compiler is not $HASH: $VER"; exit 1;; esac
OUT=results/$HASH; mkdir -p $OUT; W=$OUT/watch.txt; echo "compiler: $VER" > $W
SQ=../../sql/sqlite; CFGS="tsan tsan-sound tsan-dom_peeling-ea-lo-st-swmr"
for cfg in $CFGS; do ( cd $SQ && BUILD_ROOT=build/$HASH USE_SUMMARIES=0 ./build_sqlite_test.sh $cfg > build-$cfg.watch-$HASH.log 2>&1 ) || { echo "build failed $cfg"; exit 1; }; done
one() {  # cfg idx extra-options -> stderr file
  local cfg=$1 i=$2 extra=$3 bin wd; bin=$(readlink -f $SQ/build/$HASH/test-$cfg/threadtest3); wd=/dev/shm/watch-$HASH-$cfg-$i; rm -rf $wd; mkdir -p $wd
  ( cd $wd && TSAN_OPTIONS="print_evictions=1$extra exitcode=0 external_symbolizer_path=$F/bin/llvm-symbolizer" setarch x86_64 -R "$bin" > /dev/null 2> "$OLDPWD/$OUT/watch-$cfg-$i.err" ); rm -rf $wd
}
run_cfg() {
  local cfg=$1 base
  one $cfg 0 ""    # calibration: mapping base of test.db-shm from the run's own reports
  base=$(grep -a -m1 -oE "at 0x[0-9a-f]+ \(test.db-shm\+0x" $OUT/watch-$cfg-0.err | grep -oE "0x[0-9a-f]+" | head -1)
  [ -n "$base" ] || { echo "$cfg: no wal-index report in calibration run" >> $W; return; }
  local w; w=$(printf "0x%x+0x%x+0x%x" $((base+0x60)) $((base+0x68)) $((base+0x70)))
  echo "$cfg base=$base watch=$w" >> $W
  for i in $(seq 1 $N); do
    one $cfg $i ":evict_watch=$w"
    b2=$(grep -a -m1 -oE "at 0x[0-9a-f]+ \(test.db-shm\+0x" $OUT/watch-$cfg-$i.err | grep -oE "0x[0-9a-f]+" | head -1)
    echo "$cfg run=$i base=${b2:-none} reports=$(grep -ac 'WARNING: ThreadSanitizer: data race' $OUT/watch-$cfg-$i.err) $(grep -a 'shadow evictions' $OUT/watch-$cfg-$i.err) | $(grep -a 'evictions at' $OUT/watch-$cfg-$i.err | tr '\n' ' ')" >> $W
  done
}
for cfg in $CFGS; do run_cfg $cfg & done; wait
echo "WATCH DONE" >> $W
