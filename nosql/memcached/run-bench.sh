#!/bin/bash

NTHREADS=12
NTESTS=6

./memtier_benchmark-2.1.1/memtier_benchmark \
	--hide-histogram -t $NTHREADS -p 7777 -x $NTESTS -P memcache_text \
    --random-data \
    $@ 

echo kill `cat memcached_pid`
kill `cat memcached_pid`

if [ -e "$vtune_result_dir" ]; then
    vtune -r `pwd`/`cat vtune_result_dir` -command stop
    echo vtune -r `pwd`/`cat vtune_result_dir` -command stop
    rm vtune_result_dir memcached_pid
fi
