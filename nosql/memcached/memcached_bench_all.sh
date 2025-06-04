#!/bin/bash

echo "NAME    OPS/SEC    AVG LAT"

for VARIATION in "orig" "tsan"
do
	[ ! -f "memcached-$VARIATION/memcached" ] && continue

    echo -n "$VARIATION "
    #./build_memcached.sh $VARIATION > /dev/null 2>&1
    memcached-$VARIATION/memcached -c 4096 -t 6 -p 7777 > /dev/null 2>&1 &
    sleep 5
    taskset -c 12-19 memtier_benchmark-2.1.1/memtier_benchmark --hide-histogram -t 8 --pipeline 1024 -p 7777 -P memcache_text --random-data --test-time 10 2>&1 | grep Totals | awk '{ print $2 " " $5 }'
    # | awk '{print $2}'
    killall memcached
    sleep 5
done

#for VARIATION in "dom" "ea" "dom-ea" "lo" "dom-lo" "ea-lo" "dom-ea-lo" "st" \
#    "dom-st" "ea-st" "dom-ea-st" "lo-st" "dom-lo-st" "ea-lo-st" "dom-ea-lo-st" \
#    "swmr" "dom-swmr" "ea-swmr" "dom-ea-swmr" "lo-swmr" "dom-lo-swmr" "ea-lo-swmr" \
#    "dom-ea-lo-swmr" "st-swmr" "dom-st-swmr" "ea-st-swmr" "dom-ea-st-swmr" \
#    "lo-st-swmr" "dom-lo-st-swmr" "ea-lo-st-swmr" "dom-ea-lo-st-swmr"
for VARIATION in dom-ea-lo-st-swmr dom ea st swmr lo; do
	[ ! -f "memcached-tsan-$VARIATION/memcached" ] && continue

    echo -n "$VARIATION "
    #./build_memcached.sh tsan-$VARIATION > /dev/null 2>&1
    memcached-tsan-$VARIATION/memcached -c 4096 -t 6 -p 7777 > /dev/null 2>&1 &
    sleep 5
    taskset -c 12-19 memtier_benchmark-2.1.1/memtier_benchmark --hide-histogram -t 8 --pipeline 1024 -p 7777 -P memcache_text --random-data --test-time 10 2>&1 | grep Totals | awk '{ print $2 " " $5 }'
    killall memcached
    sleep 5
done
