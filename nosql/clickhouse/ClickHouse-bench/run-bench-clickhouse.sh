#!/bin/bash

source ../../bench_utils.sh
source clickhouse-bench-config.sh
client_nthreads=8

run_queries() {
  cat queries.sql | while read query; do
    sync
    echo "QUERY: $query" #>> $LOG_FILE
    for i in $(seq 1 $ntries); do
      echo -n "Clickhouse Query Time $i: " #>> $LOG_FILE
#set -x
      $prog client --time --format=Null --max_memory_usage=10G \
      		   	     --max_threads=$client_nthreads --query="$query" --progress 0 #>> $LOG_FILE 2>&1
#      set +x

      retval=$?
      if [ $retval -ne 0 ]; then
        echo "Something bad happend!"
#        echo $retval > ./test-exit-status
#kill -9 $prog_pid
#        sleep 3
#        exit
      fi
    done
  done
}

run_queries
cleanup_after_bench
