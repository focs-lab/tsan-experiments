#!/bin/bash

nrequests=1000000
build_type=`cat build_type`
bench="../redis-$build_type/src/redis-benchmark -n 1000000"

eval $bench

echo kill `cat prog_pid`
kill `cat prog_pid`

if [ -e "vtune_result_dir" ]; then
    vtune -r `pwd`/`cat vtune_result_dir` -command stop
    echo vtune -r `pwd`/`cat vtune_result_dir` -command stop
    rm vtune_result_dir 
fi

rm prog_pid build_type
