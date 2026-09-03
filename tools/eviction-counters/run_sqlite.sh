#!/bin/bash
# P3: shadow-eviction counters on SQLite threadtest3 (paper workload), runtime with print_evictions=1.
# Usage: ./run_sqlite.sh <frozen llvm build dir> <hash> [N]   -> results/<hash>/{counters.txt,run-<cfg>-<i>.err}
set -uo pipefail
cd "$(dirname "$0")"
F=${1:?llvm build dir}; HASH=${2:?hash}; N=${3:-5}
export LLVM_TSAN_ROOT=$F
VER=$("$F/bin/clang" --version | head -1); case "$VER" in *"$HASH"*) ;; *) echo "compiler is not $HASH: $VER"; exit 1;; esac
OUT=results/$HASH; mkdir -p $OUT; echo "compiler: $VER" > $OUT/counters.txt
SQ=../../sql/sqlite; CFGS="tsan tsan-sound tsan-dom_peeling-ea-lo-st-swmr"
for cfg in $CFGS; do ( cd $SQ && BUILD_ROOT=build/$HASH USE_SUMMARIES=0 ./build_sqlite_test.sh $cfg > build-$cfg.evict-$HASH.log 2>&1 ) || { echo "build failed $cfg"; exit 1; }; done
run_cfg() {  # one config, N sequential runs in fresh dirs
  local cfg=$1 bin
  bin=$(readlink -f $SQ/build/$HASH/test-$cfg/threadtest3)
  for i in $(seq 1 $N); do
    wd=/dev/shm/evict-$HASH-$cfg-$i; rm -rf $wd; mkdir -p $wd
    ( cd $wd && TSAN_OPTIONS="print_evictions=1 exitcode=0 external_symbolizer_path=$F/bin/llvm-symbolizer" "$bin" > /dev/null 2> "$OLDPWD/$OUT/run-$cfg-$i.err" )
    rm -rf $wd
    line=$(grep -m1 "shadow evictions" $OUT/run-$cfg-$i.err); rep=$(grep -c "WARNING: ThreadSanitizer: data race" $OUT/run-$cfg-$i.err)
    echo "$cfg run=$i reports=$rep $line" >> $OUT/counters.txt
  done
}
for cfg in $CFGS; do run_cfg $cfg & done; wait
echo "COUNTERS DONE" >> $OUT/counters.txt; cat $OUT/counters.txt
