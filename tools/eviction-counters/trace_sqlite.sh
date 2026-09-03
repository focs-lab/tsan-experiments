#!/bin/bash
# One traced run per config (trace_evictions=1): one line per uncovered eviction -> /extra (large).
set -uo pipefail; cd "$(dirname "$0")"
F=${1:?}; HASH=${2:?}; OUT=/extra/alexey/tsan-experiments/eviction-traces/$HASH; mkdir -p $OUT
for cfg in tsan tsan-dom_peeling-ea-lo-st-swmr; do
  bin=$(readlink -f ../../sql/sqlite/build/$HASH/test-$cfg/threadtest3); wd=/dev/shm/evtrace-$HASH-$cfg; rm -rf $wd; mkdir -p $wd
  ( cd $wd && TSAN_OPTIONS="print_evictions=1 trace_evictions=1 exitcode=0 external_symbolizer_path=$F/bin/llvm-symbolizer" "$bin" > /dev/null 2> $OUT/trace-$cfg.err ); rm -rf $wd
  echo "$cfg done: $(wc -l < $OUT/trace-$cfg.err) lines, $(du -h $OUT/trace-$cfg.err | cut -f1)"
done
echo "TRACE DONE"
