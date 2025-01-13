#!/bin/bash

# Default values
nthreads=$(nproc)
vtune=false
vtune_sampling_mode=hw
vtune_analysis_type=hotspots
# vtune_analysis_type=hotspots

# Usage function
usage() {
  echo "Usage: $0 -b build_type [-t nthreads] [-p]"
  echo "  -b build_type: Build type (orig or tsan or tsan-new). Default: orig"
  echo "  -t nthreads: Number of threads. Default: nproc"
  echo "  -p: Enable VTune profiling"
  exit 1
}

# Parse command-line options
while getopts ":b:t:p" opt; do
  case $opt in
    b)
      build_type="$OPTARG"
      if [[ "$build_type" != "tsan" && "$build_type" != "orig" && "$build_type" != "tsan-new" ]]; then
        echo "Error: Invalid build type: $build_type"
        usage
      fi
      echo $build_type >build_type
      ;;
    t)
      nthreads="$OPTARG"
      ;;
    p)
      vtune=true
      ;;
    \?)
      echo "Error: Invalid option: -$OPTARG"
      usage
      ;;
  esac
done

# Check if -t is provided
if [ -z "$build_type" ]; then
  echo "Error: -b option is required."
  usage
fi

# Benchmark settings
exec=redis-server
prog=../redis-$build_type/src/$exec

# Make redis config file
echo "io-threads $nthreads
io-threads-do-reads yes
tcp-keepalive 0" >redis.conf

# Vtune options
datetime_suffix=$(date +%Y-%m-%d_%H-%M)
vtune_result_dir=vtune_${exec}_${vtune_analysis_type}_${build_type}_${vtune_sampling_mode}_${datetime_suffix}
vtune_options="--collect=$vtune_analysis_type --result-dir=$vtune_result_dir \
               -knob sampling-mode=$vtune_sampling_mode \
               -knob enable-stack-collection=true \
               -data-limit=5000"

# Launch redis 
pkill "^${exec}$"
sleep 0.5

export TSAN_OPTIONS="report_bugs=0"

echo $prog redis.conf
$prog redis.conf &
PROG_PID=$!

echo $PROG_PID >prog_pid

sleep 0.3 
echo "$prog started (PID $PROG_PID)"

# Run VTune profiling
if $vtune; then
  echo $vtune_result_dir >vtune_result_dir

  echo vtune $vtune_options --target-pid $PROG_PID
	vtune $vtune_options --target-pid $PROG_PID

	echo "VTune results: $vtune_result_dir"
fi
