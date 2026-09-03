#!/bin/bash
# evict_watch on memcached's global current_time: stock / tsan-sound / tsan-all built with the frozen copy
# (runtime with evict_watch), N runs each of the paper memtier workload under setarch -R; the address comes from
# a calibration run's "Location is global 'current_time' ... at 0x..." report line (PIE, stable without ASLR).
# Waits for the whole-program memcached P2 runner to finish (single server port). Usage: ./watch_memcached.sh <llvm> <hash> [N]
set -uo pipefail; cd "$(dirname "$0")"
F=${1:?}; HASH=${2:?}; N=${3:-5}; export LLVM_TSAN_ROOT=$F
VER=$("$F/bin/clang" --version | head -1); case "$VER" in *"$HASH"*) ;; *) echo "compiler is not $HASH: $VER"; exit 1;; esac
MC=../../nosql/memcached; OUT=results/$HASH; mkdir -p $OUT; W=$OUT/watch-memcached.txt; echo "compiler: $VER" > $W
for cfg in tsan tsan-sound tsan-all; do ( cd $MC && BUILD_TAG=.watch-$HASH USE_SUMMARIES=0 ./build_memcached.sh $cfg > build-$cfg.watch-$HASH.log 2>&1 ) || { echo "build failed $cfg" | tee -a $W; exit 1; }; done
until grep -q "^done in" ../preservation/results/memcached-wp-43111f84d936.runner.log 2>/dev/null; do sleep 120; done; sleep 20
MEMTIER=$MC/memtier_benchmark-2.1.1/memtier_benchmark
one() {  # cfg idx extra -> $OUT/watch-mc-<cfg>-<i>.err
  local cfg=$1 i=$2 extra=$3 bin=$MC/memcached-$cfg.watch-$HASH/memcached
  TSAN_OPTIONS="print_evictions=1$extra exitcode=0 external_symbolizer_path=$F/bin/llvm-symbolizer" setarch x86_64 -R "$bin" -c 4096 -t $(nproc) -p 7777 -U 0 > /dev/null 2> $OUT/watch-mc-$cfg-$i.err &
  local pid=$!; for t in $(seq 1 60); do (echo > /dev/tcp/127.0.0.1/7777) 2>/dev/null && break; sleep 1; done; sleep 1
  $MEMTIER --hide-histogram -t 10 -p 7777 -x 25 --pipeline 16 -P memcache_text --random-data > /dev/null 2>&1
  kill -TERM $pid; wait $pid 2>/dev/null
}
for cfg in tsan tsan-sound tsan-all; do
  one $cfg 0 ""
  addr=$(grep -a -m1 -oE "Location is global 'current_time' of size [0-9]+ at 0x[0-9a-f]+" $OUT/watch-mc-$cfg-0.err | grep -oE "0x[0-9a-f]+$")
  [ -n "$addr" ] || { echo "$cfg: no current_time report in calibration run" >> $W; continue; }
  g=$(printf "0x%x" $((addr & ~7))); echo "$cfg current_time=$addr granule=$g" >> $W
  for i in $(seq 1 $N); do
    one $cfg $i ":evict_watch=$g"
    echo "$cfg run=$i reports=$(grep -ac 'WARNING: ThreadSanitizer: data race' $OUT/watch-mc-$cfg-$i.err) $(grep -a 'shadow evictions' $OUT/watch-mc-$cfg-$i.err) | $(grep -a 'evictions at' $OUT/watch-mc-$cfg-$i.err | tr '\n' ' ')" >> $W
  done
done
echo "WATCH-MC DONE" >> $W
