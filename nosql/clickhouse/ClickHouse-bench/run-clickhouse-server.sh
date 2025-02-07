#!/bin/bash

vtune_sampling_mode=hw

source ../../bench_utils.sh
parse_cmd $@

source clickhouse-bench-config.sh

cleanup() {
  rm -rf d* f* m* n* preprocessed_configs s* tmp u*
}

start_server() {
  printf "Starting server..."
  $prog server 2>/dev/null &
  prog_pid=$!
  sleep 5
  printf "done\n"
}

create_table_and_load_data() {
  printf "Creating table and loading data..."
  set -x
  $prog client < create-tuned.sql
  $prog client --time --query "insert into hits formaT TSV" < hits.tsv
  set +x
  echo $? > ~/test-exit-status
  printf "done\n"
}

stop_server() {
  kill -9 $prog_pid
  sleep 2
}

# Run server and make table
# cleanup
run_bench start_server
# create_table_and_load_data

# Run VTune if needed profiling
if $vtune; then
  printf "Launching vtune..."
  run_vtune
  printf "done\n"
fi

#stop_server
# cleanup
