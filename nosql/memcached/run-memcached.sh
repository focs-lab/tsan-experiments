#!/bin/bash

# Check if the config type argument is provided
if [ -z "$1" ]; then
  echo "Error: Please provide the config type (e.g., 'tsan-own-st', 'orig')."
  echo "This is used to find the build directory 'memcached-<config_type>'."
  exit 1
fi

# Memcached and benchmark settings
CONFIG_TYPE=$1 # e.g., "tsan-own-st", "orig"
MEMCACHED_BUILD_DIR="memcached-$CONFIG_TYPE"
MEMCACHED_BINARY_PATH="$MEMCACHED_BUILD_DIR/memcached"

datetime_suffix=$(date +%Y-%m-%d_%H-%M)

# Default number of threads
NTHREADS=$(nproc)
PROFILER_MODE=""

# Parse arguments to find --threads and profiler mode
# We shift past $1 (CONFIG_TYPE) which we already captured
shift 

while [[ $# -gt 0 ]]; do
    case $1 in
        --threads)
            if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
                NTHREADS="$2"
                shift 2
            else
                echo "Error: --threads requires a numeric argument."
                exit 1
            fi
            ;;
        vtune)
            PROFILER_MODE="vtune"
            shift
            ;;
        perf)
            PROFILER_MODE="perf"
            shift
            ;;
        *)
            # Ignore other arguments (like 'trace' or 'contention' passed from run-all)
            shift
            ;;
    esac
done

# Check if the memcached binary exists and is executable
if [ ! -d "$MEMCACHED_BUILD_DIR" ]; then
  echo "Error: Build directory '$MEMCACHED_BUILD_DIR' not found."
  echo "Did you run './build_memcached.sh $CONFIG_TYPE' first?"
  exit 1
fi
if [ ! -x "$MEMCACHED_BINARY_PATH" ]; then
  echo "Error: Memcached binary not found or not executable at '$MEMCACHED_BINARY_PATH'."
  exit 1
fi

# Vtune options
VTUNE_ANALYSIS_TYPE=hotspots
#VTUNE_ANALYSIS_TYPE=threading
#VTUNE_ANALYSIS_TYPE=memory-consumption
VTUNE_RESULT_DIR_BASE="vtune_memcached_${VTUNE_ANALYSIS_TYPE}_${CONFIG_TYPE}"
VTUNE_RESULT_DIR="${VTUNE_RESULT_DIR_BASE}_${datetime_suffix}" # Placed in CWD
VTUNE_OPTIONS="--collect=$VTUNE_ANALYSIS_TYPE --result-dir=$VTUNE_RESULT_DIR -knob sampling-mode=hw -knob enable-stack-collection=true"
#VTUNE_OPTIONS="--collect=$VTUNE_ANALYSIS_TYPE --result-dir=$VTUNE_RESULT_DIR"

# Kill any existing memcached instances that might conflict
# Be more specific by killing based on the binary path if possible,
# or ensure only one memcached runs if using a generic pkill.
echo "Attempting to stop any existing memcached instances..."
killall -q memcached
sleep 2.0

export TSAN_OPTIONS="report_bugs=0"

echo "--- Starting Memcached ($CONFIG_TYPE) ---"
echo "Command: $MEMCACHED_BINARY_PATH -c 4096 -t $NTHREADS -p 7777"

set -e
$MEMCACHED_BINARY_PATH -c 4096 -t $NTHREADS -p 7777 &
MEMCACHED_PID=$!
set +e

# Monitor memory usage in the background and record the peak
(
  PEAK_RSS=0
  # Give memcached a moment to start up before we start polling
  sleep 1
  # Loop as long as the memcached process is running
  while kill -0 $MEMCACHED_PID 2>/dev/null; do
    # Get current Resident Set Size (RSS) in KB
    CURRENT_RSS=$(grep VmHWM /proc/$MEMCACHED_PID/status 2>/dev/null | awk '{print $2}')
    # Check if we got a number and if it's the new peak
    if [[ -n "$CURRENT_RSS" && "$CURRENT_RSS" -gt "$PEAK_RSS" ]]; then
      PEAK_RSS=$CURRENT_RSS
    fi
    # Poll every second. A smaller interval gives more precision but uses more CPU.
    sleep 1
  done

  # Once memcached process terminates, write the result
  if [ "$PEAK_RSS" -gt 0 ]; then
    mkdir -p results
    # If the results file doesn't exist, create it with a header
    if [ ! -f "results/memory.txt" ]; then
      echo -e "configuration\tmemory" > results/memory.txt
    fi
    # Append the result for the current configuration
    echo -e "$CONFIG_TYPE\t${PEAK_RSS}K" >> results/memory.txt
    echo "Peak memory usage for $CONFIG_TYPE recorded: ${PEAK_RSS}K"
  fi
) &
# Disown the monitoring process to let it run independently of the current shell
disown $!

# Create helper files for other scripts (e.g., run-bench.sh)
echo "$MEMCACHED_PID" > memcached_pid
echo "$CONFIG_TYPE" > memcached_type # Store the short config type

echo "Memcached ($CONFIG_TYPE) started successfully (PID $MEMCACHED_PID)."

# Run VTune profiling
if [ "$PROFILER_MODE" == "vtune" ]; then
  echo "$VTUNE_RESULT_DIR" > vtune_result_dir # For run-bench.sh to find and stop
  echo "Starting VTune profiling for PID $MEMCACHED_PID..."
  echo "VTune command: vtune $VTUNE_OPTIONS --target-pid $MEMCACHED_PID"
	vtune $VTUNE_OPTIONS --target-pid $MEMCACHED_PID
	echo "VTune results: $VTUNE_RESULT_DIR"
elif [ "$PROFILER_MODE" == "perf" ]; then
  echo "Starting perf recording for PID $MEMCACHED_PID..."
	echo 1 > perf_launched
	sudo taskset -c 15 perf record -o "${MEMCACHED_BINARY_PATH}.perf" --call-graph dwarf -e cpu-cycles -p $MEMCACHED_PID
fi