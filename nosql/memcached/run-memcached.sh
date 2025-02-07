#!/bin/bash

# Check if the build type argument is provided
if [ -z "$1" ]; then
  echo "Error: Please provide the build type (tsan, tsan-new or orig)."
  exit 1
fi

if [[ "$1" != "tsan" && "$1" != "orig" && "$1" != "tsan-new" ]]; then
  echo "Error: the first argument must be 'tsan' or 'orig'."
  exit 1
fi

tsan_suffix=$1
datetime_suffix=$(date +%Y-%m-%d_%H-%M)

# Memcached and benchmark settings
#NTHREADS=`nproc`
MEMCACHED_PATH=memcached-$tsan_suffix
NTHREADS=8

# Vtune options
#VTUNE_ANALYSIS_TYPE=threading
VTUNE_ANALYSIS_TYPE=hotspots
#VTUNE_ANALYSIS_TYPE=memory-consumption
VTUNE_RESULT_DIR=vtune_memcached_${VTUNE_ANALYSIS_TYPE}_${tsan_suffix}_${datetime_suffix}
VTUNE_OPTIONS="--collect=$VTUNE_ANALYSIS_TYPE --result-dir=$VTUNE_RESULT_DIR -knob sampling-mode=hw -knob enable-stack-collection=true"
#VTUNE_OPTIONS="--collect=$VTUNE_ANALYSIS_TYPE --result-dir=$VTUNE_RESULT_DIR"

# Launch memcached 
pkill "^memcached$"
sleep 0.5
export TSAN_OPTIONS="report_bugs=0"

$MEMCACHED_PATH/memcached -c 4096 -t $NTHREADS -p 7777 &
MEMCACHED_PID=$!

echo $MEMCACHED_PID >memcached_pid

sleep 1
echo "Memcached started (PID $MEMCACHED_PID)"

# Run VTune profiling
if [ "$2" == "vtune" ]; then
    echo $VTUNE_RESULT_DIR >vtune_result_dir

    echo vtune $VTUNE_OPTIONS --target-pid $MEMCACHED_PID
	vtune $VTUNE_OPTIONS --target-pid $MEMCACHED_PID

	echo "VTune results: $VTUNE_RESULT_DIR"
fi
