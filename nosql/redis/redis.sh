#!/bin/bash
#==============================================================================
# Redis Build & Benchmark Script
# This script builds Redis with different ThreadSanitizer configurations and
# runs performance benchmarks for each build variant.
#==============================================================================

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------
# Compiler: tools/tsan_compiler.sh (sourced below, after SCRIPT_DIR is known) selects the
# hardened prototype in ~/dev/llvm-project-focs-lab unless LLVM_TSAN_ROOT is set.  The old
# LLVM_BUILD_DIR="$LLVM_PATH" is gone: ~/.bashrc exports LLVM_PATH=~/dev/llvm-project/llvm/build,
# which since 2026-05 is a symlink to the unrelated llvm-capstone tree.
LLVM_BUILD_DIR=""

# Whole-program analysis summaries (hardened compiler: opt-in, read from <cwd>/tsan-logs/).
#   USE_SUMMARIES=0  (default) optimized builds run the per-TU analyses only;
#   USE_SUMMARIES=1  copy $SUMMARIES_DIR/{st,lo,ea}_summary.txt (see ./gen_summaries.sh) into
#                    redis-<cfg>/src/tsan-logs/ and pass -mllvm -tsan-use-analysis-summaries.
USE_SUMMARIES="${USE_SUMMARIES:-0}"
SUMMARIES_DIR="${SUMMARIES_DIR:-$(dirname "$(realpath -s "$0")")/summaries}"

# Redis source archive URL
BENCH_ARCHIVE_URL="https://download.redis.io/releases/redis-7.0.15.tar.gz"
#BENCH_ARCHIVE_URL="https://github.com/redis/redis/archive/refs/tags/7.0.15.tar.gz"
#------------------------------------------------------------------------------
# Directory and File Paths
#------------------------------------------------------------------------------
SCRIPT_DIR=$(dirname "$(realpath -s "$0")")
source "$SCRIPT_DIR/../../tools/tsan_compiler.sh" || exit 1
source "$SCRIPT_DIR/../../tools/write_build_info.sh"
LLVM_BUILD_DIR="$TSAN_LLVM_ROOT"
[[ "$SUMMARIES_DIR" = /* ]] || SUMMARIES_DIR="$SCRIPT_DIR/$SUMMARIES_DIR"
BENCH_POLYGON_DIR="$SCRIPT_DIR/redis-polygon"     # Working directory for builds
BENCH_ARCHIVE_NAME=$(basename "$BENCH_ARCHIVE_URL")
RESULTS_DIR="__results_redis__"                # Main results directory
TRACES_DIR_BASE="__traces_redis__"             # Base name for local trace directories
TRACES_DIR=""
LOCAL_TRACES_DIR=""
TRACE_RAM_ROOT="/dev/shm"
TRACES_COPIED=false
TRACE_PIPE_PID=""
RESULTS_FILE="$RESULTS_DIR/compilation_time.txt"
STATS_FILE="$RESULTS_DIR/instr_count.txt"
TSAN_TMP_DIR="/tmp/__tsan__"                   # ThreadSanitizer temporary directory

#------------------------------------------------------------------------------
# Build Configuration
#------------------------------------------------------------------------------
# Available build variants:
# - orig: Original build without instrumentation
# - tsan: Basic ThreadSanitizer build
# - Various optimization combinations (dom, ea, lo, st, swmr)
#BUILD_OPTIONS="orig tsan dom ea lo st swmr dom-ea-lo-st-swmr"
#BUILD_OPTIONS="orig tsan dom dom_peeling"
#BUILD_OPTIONS="tsan tsan_no_atomics"
#BUILD_OPTIONS="orig tsan dom ea lo st swmr dom_peeling-ea-lo-st-swmr-stmt dom_peeling"

#BUILD_OPTIONS="dom_peeling-ea-lo-st-swmr-stmt dom_peeling-ea-lo-st-swmr stmt dom_peeling"
#BUILD_OPTIONS="tsan"
#BUILD_OPTIONS="orig tsan dom dom_peeling ea lo st swmr stmt dom_peeling-ea-lo-st-swmr-stmt dom_peeling-ea-lo-st-swmr"

#BUILD_OPTIONS="orig tsan dom dom_peeling dom_peeling-ea-lo-st-swmr-stmt dom_peeling-ea-lo-st-swmr"
#BUILD_OPTIONS="orig tsan"

# For tracing
#BUILD_OPTIONS="tsan ea-lo-st-swmr-stmt ea-lo-st-swmr dom_peeling-ea-lo-st-swmr-stmt dom_peeling-ea-lo-st-swmr dom-ea-lo-st-swmr dom-ea-lo-st-swmr-stmt"
#BUILD_OPTIONS="dom_peeling-ea-lo-st-swmr-stmt dom_peeling-ea-lo-st-swmr dom-ea-lo-st-swmr dom-ea-lo-st-swmr-stmt ea-lo-st-swmr-stmt ea-lo-st-swmr"
BUILD_OPTIONS="${BUILD_OPTIONS:-ea-lo-st-swmr-stmt}"
#BUILD_OPTIONS="dom_peeling-ea-lo-st-swmr-stmt dom_peeling-ea-lo-st-swmr dom-ea-lo-st-swmr dom-ea-lo-st-swmr-stmt"

#BUILD_OPTIONS="orig tsan dom ea dom-ea lo dom-lo ea-lo dom-ea-lo \
#    st dom-st ea-st dom-ea-st lo-st dom-lo-st ea-lo-st dom-ea-lo-st \
#    swmr dom-swmr ea-swmr dom-ea-swmr lo-swmr dom-lo-swmr ea-lo-swmr \
#    dom-ea-lo-swmr st-swmr dom-st-swmr ea-st-swmr dom-ea-st-swmr \
#    lo-st-swmr dom-lo-st-swmr ea-lo-st-swmr dom-ea-lo-st-swmr"
#BUILD_OPTIONS="dom-ea-lo-st-swmr"

# List of benchmark tests
#BENCHMARK_TESTS="PING_INLINE PING_MBULK SET GET INCR LPUSH RPUSH LPOP RPOP \
#    SADD HSET SPOP ZADD ZPOPMIN LPUSH LRANGE_100 LRANGE_300 LRANGE_500 LRANGE_600 MSET"

#------------------------------------------------------------------------------
# Script Execution Mode
#------------------------------------------------------------------------------
COMPILE=true
TESTS=true
TRACE_MODE=false
COUNT_INSTRUCTIONS=false

export TSAN_OPTIONS="report_bugs=0"

usage() {
    echo "Usage: $0 [ --compile-only | --test-only | trace | --help ]"
    echo ""
    echo "This script builds and benchmarks Redis with various configurations."
    echo ""
    echo "Options:"
    echo "  --compile-only   Run only the compilation part of the script."
    echo "  --test-only      Run only the benchmark tests. Assumes that the"
    echo "                   project has been compiled beforehand."
    echo "  trace            Enable trace mode. This reduces the benchmark load"
    echo "                   and redirects server output to trace files."
    echo "  --help, -h       Display this help message and exit."
    echo ""
    echo "By default (with no options), the script runs both compilation and tests."
}

# Print formatted log messages with arrow prefix
log() {
    echo "==> $1"
}

prepare_trace_dirs() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)_$$

    TRACES_DIR="$TRACE_RAM_ROOT/${TRACES_DIR_BASE}_${timestamp}"
    LOCAL_TRACES_DIR="$(pwd)/${TRACES_DIR_BASE}_${timestamp}"

    mkdir -p "$TRACES_DIR"

    log "Trace files will be written to: $TRACES_DIR"
    log "Trace files will be copied after tests to: $LOCAL_TRACES_DIR"
}

copy_traces_to_local() {
    if [ "$TRACE_MODE" != true ] || [ "$TRACES_COPIED" = true ]; then
        return 0
    fi

    wait_for_trace_pipeline || return 1

    if [ -z "$TRACES_DIR" ] || [ ! -d "$TRACES_DIR" ]; then
        return 0
    fi

    mkdir -p "$LOCAL_TRACES_DIR"

    if compgen -G "$TRACES_DIR/*" > /dev/null; then
        cp -a "$TRACES_DIR"/. "$LOCAL_TRACES_DIR"/
    fi

    rm -rf "$TRACES_DIR"
    TRACES_COPIED=true
    log "Trace files copied to: $LOCAL_TRACES_DIR"
}

wait_for_trace_pipeline() {
    local pid
    local status

    pid="${TRACE_PIPE_PID:-}"
    if [ -z "$pid" ]; then
        return 0
    fi

    TRACE_PIPE_PID=""

    if wait "$pid"; then
        return 0
    fi

    status=$?
    echo "Error: trace compression pipeline failed with exit code $status" >&2
    return "$status"
}

stop_redis_servers() {
    local pids
    mapfile -t pids < <(pgrep -x redis-server)

    if [ ${#pids[@]} -eq 0 ]; then
        return 0
    fi

    log "Found running redis-server process(es): ${pids[*]}"
    log "Stopping redis-server with SIGTERM"
    kill -TERM "${pids[@]}" 2>/dev/null || true

    local timeout=5
    local remaining
    while [ $timeout -gt 0 ]; do
        mapfile -t remaining < <(pgrep -x redis-server)
        if [ ${#remaining[@]} -eq 0 ]; then
            log "redis-server stopped gracefully."
            return 0
        fi
        sleep 5
        timeout=$((timeout - 1))
    done

    log "redis-server is still running; escalating to SIGKILL for PID(s): ${remaining[*]}"
    kill -KILL "${remaining[@]}" 2>/dev/null || true
    sleep 5

    mapfile -t remaining < <(pgrep -x redis-server)
    if [ ${#remaining[@]} -eq 0 ]; then
        log "redis-server stopped after SIGKILL."
        return 0
    fi

    echo "Error: failed to stop redis-server process(es): ${remaining[*]}" >&2
    return 1
}

# --- Argument Parsing ---
for arg in "$@"; do
    case "$arg" in
        --help|-h)
            usage
            exit 0
            ;;
        --compile-only)
            TESTS=false
            ;;
        --test-only)
            COMPILE=false
            ;;
        trace)
            TRACE_MODE=true
            ;;
        --instr-count)
            COUNT_INSTRUCTIONS=true
            ;;
    esac
done

if [ "$TRACE_MODE" = true ]; then
    log "Trace mode enabled."
fi
if [ "$COMPILE" = true ] && [ "$TESTS" = false ]; then
    log "Running in compile-only mode."
elif [ "$TESTS" = true ] && [ "$COMPILE" = false ]; then
    log "Running in test-only mode."
fi


# --- Prerequisite Check ---
[ -z "$LLVM_BUILD_DIR" ] && { echo -e "No LLVM_BUILD_DIR set\n  Example: /home/user/llvm-project/build-release"; exit 1; }

export PATH="$LLVM_BUILD_DIR/bin:$PATH"
export CC="$TSAN_CC"
export CXX="$TSAN_CXX"
export LC_ALL=en_US.UTF-8

# --- Functions ---

#------------------------------------------------------------------------------
# Utility Functions
#------------------------------------------------------------------------------

# Function to rename a directory if it exists by adding a numeric suffix if needed
rename_dir_with_suffix() {
  local dir_to_rename=$1
  local dest_base_name=$2
  if [ -d "$dir_to_rename" ]; then
    local dest_dir="$dest_base_name"
    if [ -d "$dest_dir" ]; then
      local i=1
      while [ -d "${dest_dir}${i}" ]; do
        i=$((i+1))
      done
      dest_dir="${dest_dir}${i}"
    fi
    log "Renaming '$dir_to_rename' to '$dest_dir'"
    mv "$dir_to_rename" "$dest_dir"
  else
    log "'$dir_to_rename' directory not found, skipping rename."
  fi
}

ensure_executable() {
    local path="$1"
    local description="$2"

    if [ -x "$path" ]; then
        return 0
    fi

    echo "Error: $description is missing or not executable: $path" >&2
    return 1
}

ensure_built_variant() {
    local option="$1"
    local server_bin="redis-$option${BUILD_TAG:-}/src/redis-server"

    if [ -x "$server_bin" ]; then
        return 0
    fi

    echo "Error: missing built redis-server for '$option': $server_bin" >&2
    echo "Hint: rerun without --test-only to rebuild, or inspect $RESULTS_DIR/build-$option.log if it exists." >&2
    return 1
}

function build_single_ll {
    SANITIZER=thread USE_JEMALLOC=no make -j "$(nproc)" > /dev/null 2>&1

    for MODULE in "adlist" "quicklist" "ae" "anet" "dict" "server" "sds" "zmalloc" "lzf_c" "lzf_d" "pqsort" \
                  "zipmap" "sha1" "ziplist" "release" "networking" "util" "object" "db" "replication" "rdb" \
                  "t_string" "t_list" "t_set" "t_zset" "t_hash" "config" "aof" "pubsub" "multi" "debug" "sort" \
                  "intset" "syncio" "cluster" "crc16" "endianconv" "slowlog" "eval" "bio" "rio" "rand" "memtest" \
                  "syscheck" "crcspeed" "crc64" "bitops" "sentinel" "notify" "setproctitle" "blocked" \
                  "hyperloglog" "latency" "sparkline" "redis-check-rdb" "redis-check-aof" "geo" "lazyfree" \
                  "module" "evict" "expire" "geohash" "geohash_helper" "childinfo" "defrag" "siphash" "rax" \
                  "t_stream" "listpack" "localtime" "lolwut" "lolwut5" "lolwut6" "acl" "tracking" "connection" \
                  "tls" "sha256" "timeout" "setcpuaffinity" "monotonic" "mt19937-64" "resp_parser" "call_reply" \
                  "script_lua" "script" "functions" "function_lua" "commands"
    do
        clang -pedantic -DREDIS_STATIC='' -Wno-c11-extensions -std=c11 -Wall -W -Wno-missing-field-initializers \
            -Wno-strict-prototypes -O2 -g -ggdb -fsanitize=thread -fno-sanitize-recover=all \
            -fno-omit-frame-pointer  -I../deps/hiredis -I../deps/linenoise -I../deps/lua/src -I../deps/hdr_histogram \
            -DHAVE_LIBSYSTEMD -MMD -S -emit-llvm -o "$MODULE.ll" "$MODULE.c" > /dev/null 2>&1 &
    done

    wait

    llvm-link -S -o redis-server.ll *.ll
}

function run {
    local FILE="$1"
    local TEST="$2"
    local REQUESTS="$3"
    local output
    local status
    local throughput

    echo -n "$TEST " | tee -a "$FILE"
    output=$(redis-benchmark/src/redis-benchmark \
        -P 1024 \
        -n "$REQUESTS" \
        -t "$TEST" 2>&1)
    status=$?

    if [ $status -ne 0 ]; then
        printf '%s\n' "$output" >&2
        echo "" | tee -a "$FILE"
        return $status
    fi

    throughput=$(printf '%s\n' "$output" | grep throughput | tail -1 | awk '{print $3}')
    if [ -z "$throughput" ]; then
        printf '%s\n' "$output" >&2
        echo "" | tee -a "$FILE"
        return 1
    fi

    echo "$throughput" | tee -a "$FILE"
}

# --- Main Script ---

if [ "$COMPILE" = true ]; then
    log "Creating Redis polygon"
#rm -rf "$BENCH_POLYGON_DIR"
    mkdir -p "$BENCH_POLYGON_DIR"

    log "Downloading Redis"
    cd "$BENCH_POLYGON_DIR" || exit 1
    mkdir -p "$RESULTS_DIR"
    wget "$BENCH_ARCHIVE_URL" 2> /dev/null
    BENCH_ARCHIVE_DIR=$(tar --list --file "$BENCH_ARCHIVE_NAME" | head -1)

    log "Unpacking redis-benchmark"
    tar --extract --file "$BENCH_ARCHIVE_NAME"
    mv "$BENCH_ARCHIVE_DIR" redis-benchmark

    log "Building redis-benchmark"
    cd redis-benchmark/src || exit 1
    REDIS_BENCHMARK_BUILD_LOG="../../$RESULTS_DIR/build-redis-benchmark.log"
    if ! make -j "$(nproc)" redis-benchmark > "$REDIS_BENCHMARK_BUILD_LOG" 2>&1; then
        echo "Error: failed to build redis-benchmark. See $REDIS_BENCHMARK_BUILD_LOG" >&2
        exit 1
    fi
    ensure_executable redis-benchmark redis-benchmark || exit 1
    cd ../..

    # Whole-program summaries: produced up front by ./gen_summaries.sh (uninstrumented IR of
    # the whole server, analyses run with -tsan-use-analysis-summaries).  The paper-era block
    # that emitted an instrumented redis-server.ll and ran `opt -passes=print<...>` here was
    # removed: its output was never picked up by the builds (see gen_summaries.sh header).
    if [ "$USE_SUMMARIES" = 1 ]; then
        for f in st lo ea; do
            [ -s "$SUMMARIES_DIR/${f}_summary.txt" ] || {
                echo "Error: USE_SUMMARIES=1 but $SUMMARIES_DIR/${f}_summary.txt is missing or empty (run ./gen_summaries.sh)" >&2
                exit 1
            }
        done
        log "Using whole-program summaries from $SUMMARIES_DIR"
    else
        log "USE_SUMMARIES=0: optimized builds use per-TU analyses only (no whole-program summaries)"
    fi

    # Create results directory and files
    log "Creating results directory: $RESULTS_DIR"
    mkdir -p "$RESULTS_DIR"
    echo "Compilation time (in seconds):" > "$RESULTS_FILE"
    log "Results file '$RESULTS_FILE' has been cleared."
    # Clear/create stats file
    if [ "$COUNT_INSTRUCTIONS" = true ]; then
        echo "Instrumented instruction count:" > "$STATS_FILE"
        log "Stats file '$STATS_FILE' has been cleared."
    fi
    echo ""

    # Build loop
    for OPTION in $BUILD_OPTIONS
    do
        log "Building configuration: $OPTION"
        TSAN_FLAGS=""
        SUMMARY_NOTE=""
        # BUILD_TAG (env, e.g. ".paper-compiler") keeps A/B builds with another compiler
        # (LLVM_TSAN_ROOT) next to the default ones: redis-<opt><tag>.
        DIR="redis-$OPTION${BUILD_TAG:-}"
        if [ -d "$DIR" ]; then
            if [ -f "$DIR/src/build_info.txt" ]; then
                # Same compiler stamp: a rebuild, delete. Another stamp: archive as old-builds/<dir>.<stamp>
                # (CLAUDE.md: builds of another hash are never overwritten). build_info.txt lives in src/.
                OLD_STAMP=$(build_stamp_of "$DIR/src"); CUR_STAMP=$(compiler_stamp_of "$TSAN_CC")
                if [ -n "$OLD_STAMP" ] && [ "$OLD_STAMP" = "$CUR_STAMP" ]; then
                    rm -rf "$DIR"
                else
                    mkdir -p old-builds; rm -rf "old-builds/$DIR.${OLD_STAMP:-unknown}"
                    log "Archiving build of another compiler $DIR -> old-builds/$DIR.${OLD_STAMP:-unknown}"
                    mv "$DIR" "old-builds/$DIR.${OLD_STAMP:-unknown}"
                fi
            else
                # A build without build_info.txt predates this script version (paper-era
                # binary): keep it for provenance instead of deleting it.
                OLD_STAMP=$(date -r "$( [ -f "$DIR/src/redis-server" ] && echo "$DIR/src/redis-server" || echo "$DIR" )" +%Y%m%d)
                mkdir -p old-builds
                log "Archiving paper-era build $DIR -> old-builds/$DIR.$OLD_STAMP"
                rm -rf "old-builds/$DIR.$OLD_STAMP"
                mv "$DIR" "old-builds/$DIR.$OLD_STAMP"
            fi
        fi

        # Rename the temporary TSan directory before the build
        rename_dir_with_suffix "$TSAN_TMP_DIR" "${TSAN_TMP_DIR}_redis_old"
        # Recreate the directory for the current build
        mkdir -p "$TSAN_TMP_DIR"

        tar --extract --file "$BENCH_ARCHIVE_NAME"
        mv "$BENCH_ARCHIVE_DIR" "$DIR"
        cd "$DIR"/src || exit 1

        start_time=$SECONDS
        BUILD_LOG="../../$RESULTS_DIR/build-$OPTION.log"

        if [[ "$OPTION" = "orig" ]]
        then
            log "Building orig"
            if ! USE_JEMALLOC=no make redis-server -j "$(nproc)" > "$BUILD_LOG" 2>&1; then
                echo "Error: build failed for '$OPTION'. See $BUILD_LOG" >&2
                exit 1
            fi
        elif [[ "$OPTION" = "tsan" ]]
        then
            if ! SANITIZER=thread USE_JEMALLOC=no make redis-server -j "$(nproc)" > "$BUILD_LOG" 2>&1; then
                echo "Error: build failed for '$OPTION'. See $BUILD_LOG" >&2
                exit 1
            fi
        else
            TSAN_FLAGS=""
            SUMMARY_NOTE="summaries: none (per-TU analyses only)"
            if [ "$USE_SUMMARIES" = 1 ]; then
                # Sound summaries interface (tsan-dev fafbebedb41e+): files are tagged with
                # "# tsan-summary-id: <tag>", read from -tsan-summary-dir with the matching
                # -tsan-summary-id, never overwritten by a seeded compile.
                SUMMARY_ID=$(sed -n 's/^# tsan-summary-id: *//p' "$SUMMARIES_DIR/st_summary.txt" | head -1)
                [ -n "$SUMMARY_ID" ] || { echo "Error: $SUMMARIES_DIR/st_summary.txt has no '# tsan-summary-id:' header (regenerate with gen_summaries.sh)" >&2; exit 1; }
                SUMMARIES_ABS=$(readlink -f "$SUMMARIES_DIR")
                TSAN_FLAGS="$TSAN_FLAGS -mllvm -tsan-use-analysis-summaries -mllvm -tsan-summary-dir=$SUMMARIES_ABS -mllvm -tsan-summary-id=$SUMMARY_ID"
                SUMMARY_NOTE="summaries: $SUMMARIES_DIR id=$SUMMARY_ID ($(md5sum "$SUMMARIES_DIR"/{st,lo,ea}_summary.txt | awk '{print $1}' | cut -c1-8 | tr '\n' ' '))"
            fi

            # Option name -> flags, matched per '-'-separated token (the paper-era substring
            # match `*"st"*` also fired for "stmt", so the stand-alone stmt build had STC on).
            for TOKEN in ${OPTION//-/ }; do
                case "$TOKEN" in
                    tsan_no_atomics) TSAN_FLAGS="$TSAN_FLAGS -mllvm -tsan-instrument-atomics=false" ;;
                    lo)          TSAN_FLAGS="$TSAN_FLAGS -mllvm -tsan-use-lock-ownership" ;;
                    swmr)        TSAN_FLAGS="$TSAN_FLAGS -mllvm -tsan-use-swmr" ;;
                    st)          TSAN_FLAGS="$TSAN_FLAGS -mllvm -tsan-use-single-threaded" ;;
                    stmt)        TSAN_FLAGS="$TSAN_FLAGS -mllvm -tsan-use-active-thread-count" ;;
                    ea)          TSAN_FLAGS="$TSAN_FLAGS -mllvm -tsan-use-escape-analysis-global" ;;
                    dom)         TSAN_FLAGS="$TSAN_FLAGS -mllvm -tsan-use-dominance-analysis" ;;
                    dom_peeling) TSAN_FLAGS="$TSAN_FLAGS -mllvm -tsan-use-dominance-analysis -mllvm -tsan-use-loop-peeling=true" ;;
                    # Rebuttal (plan P2/P3): the four sound analyses, i.e. AllOpt without DE.
                    sound)       TSAN_FLAGS="$TSAN_FLAGS -mllvm -tsan-use-escape-analysis-global -mllvm -tsan-use-lock-ownership -mllvm -tsan-use-single-threaded -mllvm -tsan-use-swmr" ;;
                    *) echo "Error: unknown option token '$TOKEN' in '$OPTION'" >&2; exit 1 ;;
                esac
            done
            # EXTRA_TSAN_FLAGS: diagnostic flags appended verbatim (e.g. -mllvm -tsan-ea-flow-insensitive);
            # combine with BUILD_TAG so that such builds never replace the canonical redis-<option> dirs.
            TSAN_FLAGS="$TSAN_FLAGS ${EXTRA_TSAN_FLAGS:-}"

            # The flags go through REDIS_CFLAGS, not CFLAGS: a CFLAGS value coming from the
            # environment is auto-exported by make to the deps/ sub-make together with the
            # `-fsanitize=thread` that src/Makefile appends for SANITIZER=thread, so the
            # paper-era builds (CFLAGS="$TSAN_FLAGS") instrumented lua, hiredis and
            # hdr_histogram in every optimized build but NOT in the plain `tsan` baseline
            # (compare deps/.make-cflags of the March builds: ~500 extra instrumented
            # functions, e.g. luaV_execute, redisReaderGetReply, hdr_record_value).
            # REDIS_CFLAGS only reaches src/ (FINAL_CFLAGS), so deps are treated the same
            # way in all configurations (uninstrumented, as in the baseline).
            log "Building $OPTION"
            if ! SANITIZER=thread USE_JEMALLOC=no REDIS_CFLAGS="$TSAN_FLAGS" make redis-server -j "$(nproc)" > "$BUILD_LOG" 2>&1; then
                echo "Error: build failed for '$OPTION'. See $BUILD_LOG" >&2
                exit 1
            fi
        fi

        ensure_executable redis-server "redis-server for '$OPTION'" || { echo "Hint: build log is $BUILD_LOG" >&2; exit 1; }

        if [ "$USE_SUMMARIES" = 1 ] && [[ "$OPTION" != "orig" && "$OPTION" != "tsan" ]] && [ -z "${SUMMARY_ID:-}" ]; then   # legacy tsan-logs/ copy only
            for f in st lo ea; do
                cmp -s "$SUMMARIES_DIR/${f}_summary.txt" "tsan-logs/${f}_summary.txt" || {
                    echo "Error: tsan-logs/${f}_summary.txt was modified during the build of '$OPTION'" >&2; exit 1; }
            done
        fi
        write_build_info . "$CC" "SANITIZER=$([[ "$OPTION" = orig ]] && echo none || echo thread) REDIS_CFLAGS=${TSAN_FLAGS:-}" \
            "config: $OPTION" "${SUMMARY_NOTE:-summaries: n/a}"

        duration=$(( SECONDS - start_time ))
        log "Finished building '$OPTION' in $duration seconds."

        # Write compilation time to the file
        echo "$OPTION: $duration" >> "../../$RESULTS_FILE"
        log "Result for '$OPTION' saved to $RESULTS_FILE"

        # Summarize and save instruction stats
        if [ "$COUNT_INSTRUCTIONS" = true ]; then
            log "Summarizing instruction statistics for $OPTION"
            instr_count=$(summarize_instr_stats.py)
            log "Instrumented instructions: $instr_count"
            echo "$OPTION: $instr_count" >> "../../$STATS_FILE"
            log "Result for '$OPTION' saved to $STATS_FILE"
        fi

        cd ../..
        log "----------------------------------------"
    done
fi


if [ "$TESTS" = true ]; then
    log "Checking for pre-existing redis-server processes before running benchmarks."
    stop_redis_servers || exit 1

    if [ "$COMPILE" = false ]; then
        log "Switching to polygon directory for tests."
        if [ ! -d "$BENCH_POLYGON_DIR" ]; then
            log "Error: Build directory '$BENCH_POLYGON_DIR' not found. Cannot run tests."
            log "Run the script without --test-only first to create the builds."
            exit 1
        fi
        cd "$BENCH_POLYGON_DIR" || exit 1
    fi

    ensure_executable "redis-benchmark/src/redis-benchmark" "redis-benchmark" || exit 1

    # A simple check to see if builds might be present
    if [ ! -d "redis-orig" ]; then
        log "Warning: 'redis-orig' build not found. Assuming other builds exist."
    fi
    if [ ! -d "$RESULTS_DIR" ]; then
        log "Results directory '$RESULTS_DIR' not found. Creating it."
        mkdir -p "$RESULTS_DIR"
    fi

    cp -r "$SCRIPT_DIR/redis.conf" .

    # --- Benchmark Settings ---
    REQ_GENERAL=1000000
    REQ_LPUSH=1000000
    REQ_LRANGE100=50000
    REQ_LRANGE300=10000
    REQ_LRANGE500=5000
    REQ_LRANGE600=3000
    REQ_MSET=100000

    if [ "$TRACE_MODE" = true ]; then
        log "Reducing benchmark load for trace mode."
        prepare_trace_dirs || exit 1
        trap 'copy_traces_to_local || true' EXIT

        REQ_GENERAL=$((REQ_GENERAL / 50000))
        REQ_LPUSH=$((REQ_LPUSH / 500000))
        REQ_LRANGE100=$((REQ_LRANGE100 / 5000))
        REQ_LRANGE300=$((REQ_LRANGE300 / 1000))
        REQ_LRANGE500=$((REQ_LRANGE500 / 1000))
        REQ_LRANGE600=$((REQ_LRANGE600 / 1000))
        REQ_MSET=$((REQ_MSET / 1000))
    fi

    # --- Benchmark Loop ---
    BENCH_RESULTS_FILE="$RESULTS_DIR/results.txt"
    : > "$BENCH_RESULTS_FILE"
    for OPTION in $BUILD_OPTIONS
    do
        log "Testing $OPTION"
        echo "==> Testing $OPTION" >> "$BENCH_RESULTS_FILE"
        mkdir -p "$RESULTS_DIR/benchmarks"

        stop_redis_servers || exit 1
        ensure_built_variant "$OPTION" || exit 1
        SERVER_BIN="redis-$OPTION${BUILD_TAG:-}/src/redis-server"

        if [ "$TRACE_MODE" = true ]; then
            TRACE_FILE="$TRACES_DIR/${OPTION}.trace"
            log "Redirecting trace output to ${TRACE_FILE}.zst"
            "$SERVER_BIN" redis.conf 2>&1 | zstd -1 -o "${TRACE_FILE}.zst" &
            TRACE_PIPE_PID=$!
        else
            echo -n "$OPTION " >> "$RESULTS_DIR/memory.txt"
            /usr/bin/time --verbose "$SERVER_BIN" redis.conf 2>&1 | grep "Maximum resident set size" | awk '{print $6}' >> "$RESULTS_DIR/memory.txt" &
        fi
        
        sleep 5
        
        # Paper-era: 'orig' got 10x the requests (REDIS_ORIG_MULT=10); performance sweeps use 1 (same N).
        [[ "$OPTION" = "orig" && "${REDIS_ORIG_MULT:-1}" = "10" ]] && L="0" || L=""
        
        run "$BENCH_RESULTS_FILE" PING_INLINE "${REQ_GENERAL}${L}" || exit 1
        run "$BENCH_RESULTS_FILE" PING_MBULK  "${REQ_GENERAL}${L}" || exit 1
        run "$BENCH_RESULTS_FILE" SET         "${REQ_GENERAL}${L}" || exit 1
        run "$BENCH_RESULTS_FILE" GET         "${REQ_GENERAL}${L}" || exit 1
        run "$BENCH_RESULTS_FILE" INCR        "${REQ_GENERAL}${L}" || exit 1
        run "$BENCH_RESULTS_FILE" RPUSH       "${REQ_GENERAL}${L}" || exit 1
        run "$BENCH_RESULTS_FILE" LPOP        "${REQ_GENERAL}${L}" || exit 1
        run "$BENCH_RESULTS_FILE" RPOP        "${REQ_GENERAL}${L}" || exit 1
        run "$BENCH_RESULTS_FILE" SADD        "${REQ_GENERAL}${L}" || exit 1
        run "$BENCH_RESULTS_FILE" HSET        "${REQ_GENERAL}${L}" || exit 1
        run "$BENCH_RESULTS_FILE" SPOP        "${REQ_GENERAL}${L}" || exit 1
        run "$BENCH_RESULTS_FILE" ZADD        "${REQ_GENERAL}${L}" || exit 1
        run "$BENCH_RESULTS_FILE" ZPOPMIN     "${REQ_GENERAL}${L}" || exit 1
        run "$BENCH_RESULTS_FILE" LPUSH       "${REQ_LPUSH}${L}" || exit 1
        if [ "$TRACE_MODE" = false ]; then
          run "$BENCH_RESULTS_FILE" LRANGE_100  "${REQ_LRANGE100}${L}" || exit 1
          run "$BENCH_RESULTS_FILE" LRANGE_300  "${REQ_LRANGE300}${L}" || exit 1
          run "$BENCH_RESULTS_FILE" LRANGE_500  "${REQ_LRANGE500}${L}" || exit 1
          run "$BENCH_RESULTS_FILE" LRANGE_600  "${REQ_LRANGE600}${L}" || exit 1
          run "$BENCH_RESULTS_FILE" MSET        "${REQ_MSET}${L}" || exit 1
        fi
        
        stop_redis_servers || exit 1
        if [ "$TRACE_MODE" = true ]; then
            wait_for_trace_pipeline || exit 1
        fi
        sleep 5
        rm -f dump.rdb
    done

    if [ "$TRACE_MODE" = true ]; then
        copy_traces_to_local || exit 1
        trap - EXIT
    fi
fi

log "Script finished successfully. All results are in $RESULTS_DIR"

if [ "$TRACE_MODE" = true ] && [ -n "$LOCAL_TRACES_DIR" ]; then
    cd "$LOCAL_TRACES_DIR" || exit 1
    analyze_trace2_zst_in_current_dir.sh
fi
