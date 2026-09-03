#!/bin/bash
# Short traced memcached runs (trace_evictions=1) to split the uncovered evictions on the current_time
# granule into read vs write records, per build. Small memtier workload; ASLR off.
set -uo pipefail; cd "$(dirname "$0")"
F=/extra/alexey/builds/tsan-audit-43111f84d936; HASH=43111f84d936; MC=../../nosql/memcached
OUT=/extra/alexey/tsan-experiments/eviction-traces/memcached-$HASH; mkdir -p $OUT
for cfg in tsan tsan-sound tsan-all; do
  bin=$MC/memcached-$cfg.watch-$HASH/memcached
  TSAN_OPTIONS="print_evictions=1:trace_evictions=1 exitcode=0 external_symbolizer_path=$F/bin/llvm-symbolizer" setarch x86_64 -R "$bin" -c 4096 -t $(nproc) -p 7777 -U 0 > /dev/null 2> $OUT/trace-$cfg.err &
  pid=$!; for t in $(seq 1 60); do (echo > /dev/tcp/127.0.0.1/7777) 2>/dev/null && break; sleep 1; done; sleep 3
  $MC/memtier_benchmark-2.1.1/memtier_benchmark --hide-histogram -t 10 -p 7777 -x 1 --pipeline 16 -P memcache_text --random-data --requests 20000 > /dev/null 2>&1
  kill -TERM $pid; wait $pid 2>/dev/null
  addr=$(grep -a -m1 -oE "Location is global 'current_time' of size [0-9]+ at 0x[0-9a-f]+" $OUT/trace-$cfg.err | grep -oE "0x[0-9a-f]+$")
  g=$(printf "0x%x" $((addr & ~7)))
  echo "== $cfg current_time=$addr granule=$g lines=$(wc -l < $OUT/trace-$cfg.err) $(grep -a 'shadow evictions' $OUT/trace-$cfg.err)"
  grep -a "evicted concurrent .* at $g " $OUT/trace-$cfg.err | sed -E 's/.*evicted concurrent (plain|atomic) (read|write) at .*/\1 \2/' | sort | uniq -c
done
echo "MC-TRACE DONE"
