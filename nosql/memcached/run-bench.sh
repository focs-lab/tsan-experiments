#!/bin/bash

NTHREADS=${NTHREADS:-10}
NTESTS=${NTESTS:-5}          # memtier iterations (-x); the same for every configuration
MEMTIER_EXTRA_ARGS=""
MEMCACHED_TYPE=$(cat memcached_type)
# (the paper-era "x5 iterations when the type is tsan" rule was removed: unequal N inside the comparison)

# Check for trace argument
for arg in "$@"; do
    if [ "$arg" = "trace" ]; then
        MEMTIER_EXTRA_ARGS="--requests 500"
        NTESTS=1
        break
    fi
done

mkdir -p results

./memtier_benchmark-2.1.1/memtier_benchmark \
	--hide-histogram -t $NTHREADS -p 7777 -x $NTESTS --pipeline 16 -P memcache_text \
    --random-data \
    $MEMTIER_EXTRA_ARGS \
    | tee "results/${MEMCACHED_TYPE}_results.txt"

echo -e "\e[94mmemcached type: ${MEMCACHED_TYPE}\e[m"

echo kill `cat memcached_pid`
kill `cat memcached_pid`
rm memcached_pid memcached_type

if [ -e "vtune_result_dir" ]; then
  vtune -r `pwd`/`cat vtune_result_dir` -command stop
  echo vtune -r `pwd`/`cat vtune_result_dir` -command stop
  rm vtune_result_dir
elif [ -e "perf_launched" ]; then
	echo Perf should be finished now.
	rm perf_launched
fi