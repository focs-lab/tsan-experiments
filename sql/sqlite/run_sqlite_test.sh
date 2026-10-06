#!/bin/bash

# --- Argument Parsing ---
if [ -z "$1" ]; then
  echo "Usage: $0 <config_type> [nthreads] [vtune] [trace]"
  echo "Description: Runs the threadtest3 benchmark for a given build configuration."
  echo ""
  echo "Arguments:"
  echo "  <config_type>: The name of the configuration to run (e.g., 'orig', 'tsan-lo')."
  echo "                 This corresponds to a build directory at 'build/test-<config_type>'."
  echo "  [nthreads]:    (Optional) Number of threads for walthread1 and walthread3 tests."
  echo "  [vtune]:       (Optional) If specified, runs the test with Intel VTune profiling."
  echo "  [trace]:       (Optional) If specified, compress the output log file using zstd."
  echo ""
  echo "Example:"
  echo "  ./run_sqlite_test.sh tsan-lo"
  echo "  ./run_sqlite_test.sh tsan-lo 4"
  echo "  ./run_sqlite_test.sh tsan-lo vtune"
  echo "  ./run_sqlite_test.sh tsan-lo trace"
  exit 1
fi

CONFIG_TYPE=$1
shift # Consume config_type, the rest of the arguments are in $@

# Process optional arguments
NTHREADS=""
USE_VTUNE=false
USE_TRACE=false
VTUNE_SAMPLING_MODE="hw"   # can be overridden by passing vtune-sw / vtune-hw
for arg in "$@"; do
    case "$arg" in
        vtune)
            USE_VTUNE=true
            ;;
        vtune-sw)
            USE_VTUNE=true
            VTUNE_SAMPLING_MODE="sw"
            ;;
        vtune-hw)
            USE_VTUNE=true
            VTUNE_SAMPLING_MODE="hw"
            ;;
        trace)
            USE_TRACE=true
            ;;
        *[!0-9]*)
            echo "Warning: Ignoring unknown non-numeric argument '$arg'"
            ;;
        *)
            if [ -n "$NTHREADS" ]; then
                echo "Warning: Number of threads specified more than once. Using last value: $arg"
            fi
            NTHREADS=$arg
            ;;
    esac
done


BUILD_DIR="${BUILD_ROOT:-build}/test-$CONFIG_TYPE"
EXECUTABLE_PATH="$BUILD_DIR/threadtest3"
# Stale state from earlier runs/compiles in this directory: summary files the compiler may pick up
# (tsan-logs/ is the legacy default summary dir), and databases left by an aborted threadtest3.
rm -rf tsan-logs lo_summary.txt st_summary.txt ea_summary.txt test.db test.db-* test_sv.db test_sv.db-* 2>/dev/null

# --- Result and Output Setup ---
RESULTS_DIR="results"
VTUNE_RESULTS_ROOT="vtune_results"
mkdir -p "$RESULTS_DIR"

# Prepare memory results file
MEMORY_RESULTS_FILE="$RESULTS_DIR/memory.txt"
# If the memory results file doesn't exist, create it with a header
if [ ! -f "$MEMORY_RESULTS_FILE" ]; then
    echo -e "configuration\tmemory (KB)" > "$MEMORY_RESULTS_FILE"
fi

# --- Executable Validation ---
if [ ! -x "$EXECUTABLE_PATH" ]; then
  echo "Error: Test executable not found or not executable at '$EXECUTABLE_PATH'."
  echo "Please ensure you have built this configuration first by running:"
  echo "  ./build_sqlite_test.sh $CONFIG_TYPE"
  exit 1
fi

if [ "$USE_VTUNE" = true ]; then
    mkdir -p "$VTUNE_RESULTS_ROOT"
fi

# --- Test Execution ---
echo "--- Running Benchmark for: $CONFIG_TYPE ---"

# Set TSAN_OPTIONS to get a summary report instead of stopping at the first data race.
# This ensures the benchmark runs to completion.
export TSAN_OPTIONS="report_bugs=0"

# Base command to execute the test
CMD="$EXECUTABLE_PATH"

if [ -n "$NTHREADS" ]; then
    #    CMD="$CMD --w1-threads $NTHREADS --w3-threads $NTHREADS walthread1 walthread3"
    # SQLITE_TESTS selects which subtests run alongside the thread count. The default keeps the contention
    # sweeps' behaviour exactly (walthread1 alone, which is all the 13-18 September sweep measured); the
    # campaign sets SQLITE_TESTS='*' to get the whole suite at a chosen walthread1 thread count.
    #
    # '*' rather than an explicit seven-name list because that is precisely what threadtest3 does for itself
    # when given no arguments at all: threadtest3.c:1522 defines `substArgv[] = { 0, "*", 0 }` and
    # substitutes it when argc < 2. So '*' reproduces the default test selection instead of re-stating it,
    # and cannot drift from it if the suite gains a test. Note that a bare `--w1-threads N` with no test
    # argument does NOT run everything: argc is then 3, substArgv is not substituted, and the selection loop
    # globs the number itself against the test names, matches nothing, and exits with the usage message.
    CMD="$CMD --w1-threads $NTHREADS ${SQLITE_TESTS:-walthread1}"
    RESULTS_DIR=${RESULTS_DIR}/contention
    mkdir -p "$RESULTS_DIR"
    RESULT_FILE="$RESULTS_DIR/${CONFIG_TYPE}_${NTHREADS}threads.log"
else
    # SQLITE_TESTS without a thread count selects subtests for the ordinary run (unset: threadtest3's own default,
    # the whole suite). Used from 25 Sep 2026 to run only the seven subtests the speedup readout uses
    # (walthread1 walthread2 dynamic_triggers checkpoint_starvation_1 checkpoint_starvation_2 stress1 stress2),
    # about half the time per run; the log's "Running <name>" lines record which subtests ran.
    [ -n "${SQLITE_TESTS:-}" ] && CMD="$CMD $SQLITE_TESTS"
    RESULT_FILE="$RESULTS_DIR/${CONFIG_TYPE}.log"
fi

# If tracing is enabled, append .zst to the result file name
if [ "$USE_TRACE" = true ]; then
    RESULT_FILE="${RESULT_FILE}.zst"
fi


# If VTune is enabled, wrap the command
if [ "$USE_VTUNE" = true ]; then
    VTUNE_ANALYSIS_TYPE="hotspots" # Common analysis types: hotspots, threading, memory-consumption
    VTUNE_RESULT_DIR="$VTUNE_RESULTS_ROOT/sqlite_${CONFIG_TYPE}_$(date +%Y-%m-%d_%H-%M)"

    #
    # Flame graph in VTune requires call stacks.
    # For sampling this usually means:
    #  - knobs: enable stack collection (and optionally set stackwalk method)
    #  - build: keep debug symbols and preferably frame pointers
    #
    # NOTE: hw sampling may produce limited/empty stacks on some platforms/kernels.
    # If you don't see stacks/flamegraph, try passing `vtune-sw`.
    #
    VTUNE_OPTIONS="--collect=$VTUNE_ANALYSIS_TYPE --result-dir=$VTUNE_RESULT_DIR"
    VTUNE_OPTIONS+=" -knob sampling-mode=${VTUNE_SAMPLING_MODE}"
    VTUNE_OPTIONS+=" -knob enable-stack-collection=true"
#    VTUNE_OPTIONS+=" -knob stackwalk=offline"   # best-effort, doesn't require unwinding during collection
    VTUNE_OPTIONS+=" -data-limit=0"             # avoid premature stop at 1000MB (can kill stacks)

    echo "VTune Profiling: ENABLED"
    echo "VTune Analysis Type: $VTUNE_ANALYSIS_TYPE"
    echo "VTune sampling mode: $VTUNE_SAMPLING_MODE"
    echo "VTune results will be stored in: $VTUNE_RESULT_DIR"

    # Prepend the vtune command and its options
    CMD="vtune $VTUNE_OPTIONS -- $CMD"
fi

echo "Executable: $EXECUTABLE_PATH"
echo "Full Command: $CMD"
echo "Output will be saved to: $RESULT_FILE"
echo "Memory usage will be saved to: $MEMORY_RESULTS_FILE"
echo "Running, please wait..."

# Prepend the /usr/bin/time command to capture memory usage.
# -a appends to the output file.
# -o specifies the output file for the time command.
# -f formats the output. %M gives the maximum resident set size in Kilobytes.
# We use a tab character for formatting.
TIME_CMD="/usr/bin/time -a -o $MEMORY_RESULTS_FILE -f '$CONFIG_TYPE\t%M'"

# SQLITE_DB_DIR (4 Oct 2026): run threadtest3 from a fresh directory under this path (e.g. /dev/shm, a tmpfs), so its
# test.db files live there instead of in this directory on disk. The result and memory files stay here. Unset: unchanged.
if [ -n "${SQLITE_DB_DIR:-}" ]; then
    RESULT_FILE="$(realpath -m "$RESULT_FILE")"; MEMORY_RESULTS_FILE="$(realpath -m "$MEMORY_RESULTS_FILE")"
    CMD="${CMD/$EXECUTABLE_PATH/$(realpath "$EXECUTABLE_PATH")}"
    TIME_CMD="/usr/bin/time -a -o $MEMORY_RESULTS_FILE -f '$CONFIG_TYPE\t%M'"
    DB_RUN_DIR="$(mktemp -d "$SQLITE_DB_DIR/sqlite-run.XXXXXX")" || { echo "cannot create a run directory in $SQLITE_DB_DIR"; exit 1; }
    trap 'rm -rf "$DB_RUN_DIR"' EXIT
    cd "$DB_RUN_DIR" || exit 1
    echo "Databases in: $DB_RUN_DIR"
fi

CMD_STATUS=0
if [ "$USE_TRACE" = true ]; then
    echo "Trace enabled. Compressing output with zstd."
    # Execute the command and pipe both stdout and stderr to zstd for compression.
    # The exit code of the benchmark command (the first command in the pipe) is captured using PIPESTATUS.
    eval $TIME_CMD $CMD 2>&1 | zstd -1 -o "$RESULT_FILE"
    CMD_STATUS=${PIPESTATUS[0]}
else
    # Execute the command, redirecting both stdout and stderr to the result file.
    eval $TIME_CMD $CMD &> "$RESULT_FILE"
    CMD_STATUS=$?
fi


# Check the exit code of the executed command
if [ $CMD_STATUS -eq 0 ]; then
    echo "--- Benchmark for [$CONFIG_TYPE] completed successfully. ---"
else
    # The TSan runtime exits with a non-zero code if races are found. This is expected.
    if [[ "$CONFIG_TYPE" == tsan* ]]; then
        echo "--- Benchmark for TSan configuration [$CONFIG_TYPE] completed. ---"
        echo "NOTE: A non-zero exit code is expected for TSan when data races are detected."
    else
        echo "--- Benchmark for [$CONFIG_TYPE] FAILED with a non-zero exit code. ---"
    fi
    echo "Please check the log file for details: $RESULT_FILE"
fi

echo ""