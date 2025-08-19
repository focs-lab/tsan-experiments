#!/bin/bash
#==============================================================================
# Redis Build & Benchmark Script
# This script builds Redis with different ThreadSanitizer configurations and
# runs performance benchmarks for each build variant.
#==============================================================================

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------
LLVM_BUILD_DIR="$LLVM_PATH"

# Redis source archive URL
BENCH_ARCHIVE_URL="https://download.redis.io/releases/redis-7.0.15.tar.gz"
#BENCH_ARCHIVE_URL="https://github.com/redis/redis/archive/refs/tags/7.0.15.tar.gz"
#------------------------------------------------------------------------------
# Directory and File Paths
#------------------------------------------------------------------------------
BENCH_POLYGON_DIR="/dev/shm/redis-polygon"     # Working directory for builds
BENCH_ARCHIVE_NAME=$(basename "$BENCH_ARCHIVE_URL")
SCRIPT_DIR=$(dirname $(realpath -s "$0"))

# Results and statistics directories
RESULTS_DIR="__results_redis__"                # Main results directory
TRACES_DIR="__traces_redis__"                  # Traces directory
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
BUILD_OPTIONS="orig tsan dom ea lo st swmr dom-ea-lo-st-swmr"
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
export CC=clang
export CXX=clang++
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


function build_single_ll {
    SANITIZER=thread USE_JEMALLOC=no make -j $(nproc) > /dev/null 2>&1

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

    wait `jobs -p`

    llvm-link -S -o redis-server.ll *.ll
}

function run {
    FILE="$1"
    TEST="$2"
    REQUESTS="$3"

    echo -n "$TEST " | tee -a "$FILE"
    redis-benchmark/src/redis-benchmark \
        -P 1024 \
        -n "$REQUESTS" \
        -t "$TEST" | grep throughput | tail -1 | awk '{print $3}' | tee -a "$FILE"
}

# --- Main Script ---

if [ "$COMPILE" = true ]; then
    log "Creating Redis polygon"
    rm -rf "$BENCH_POLYGON_DIR"
    mkdir "$BENCH_POLYGON_DIR"

    log "Downloading Redis"
    cd "$BENCH_POLYGON_DIR"
    wget "$BENCH_ARCHIVE_URL" 2> /dev/null
    BENCH_ARCHIVE_DIR=$(tar --list --file "$BENCH_ARCHIVE_NAME" | head -1)

    log "Unpacking redis-benchmark"
    tar --extract --file "$BENCH_ARCHIVE_NAME"
    mv "$BENCH_ARCHIVE_DIR" redis-benchmark

    log "Building redis-benchmark"
    cd redis-benchmark/src
    make -j $(nproc) redis-benchmark > /dev/null 2>&1
    cd ../..

    if [[ -d "$SCRIPT_DIR/summaries" ]]
    then
        log "Ready summaries found"
        cp -r "$SCRIPT_DIR/summaries" .
    else
        log "Building a single LL"
        tar --extract --file "$BENCH_ARCHIVE_NAME"
        mv "$BENCH_ARCHIVE_DIR" redis-single-ll
        cd redis-single-ll/src
        build_single_ll
        cd ../..

        log "Building summaries (may take a long time)"
        mkdir summaries
        cd summaries
        mkdir single-threaded lock-ownership escape-analysis-global
        cp ../redis-single-ll/src/redis-server.ll single-threaded
        cp ../redis-single-ll/src/redis-server.ll lock-ownership
        cp ../redis-single-ll/src/redis-server.ll escape-analysis-global
        cd single-threaded
        opt -S -disable-output -passes='print<single-threaded>' -debug-only=single-threaded redis-server.ll 2> /dev/null &
        cd ../lock-ownership
        opt -S -disable-output -passes='print<lock-ownership>' -debug-only=lock-ownership redis-server.ll 2> /dev/null &
        cd ../escape-analysis-global
        opt -S -disable-output -passes='print<escape-analysis-global>' -debug-only=ea-escaping-callees redis-server.ll 2> /dev/null &
        wait `jobs -p`
        cd ../..
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

        # Rename the temporary TSan directory before the build
        rename_dir_with_suffix "$TSAN_TMP_DIR" "${TSAN_TMP_DIR}_redis_old"
        # Recreate the directory for the current build
        mkdir -p "$TSAN_TMP_DIR"

        tar --extract --file "$BENCH_ARCHIVE_NAME"
        mv "$BENCH_ARCHIVE_DIR" "redis-$OPTION"
        cd "redis-$OPTION"/src

        start_time=$SECONDS

        if [[ "$OPTION" = "orig" ]]
        then
            USE_JEMALLOC=no make redis-server -j $(nproc) > /dev/null 2>&1
        elif [[ "$OPTION" = "tsan" ]]
        then
            SANITIZER=thread USE_JEMALLOC=no make redis-server -j $(nproc) > /dev/null 2>&1
        else
            [ -d "../../summaries/escape-analysis-global/ea-logs" ] && \
              cp -r ../../summaries/escape-analysis-global/ea-logs .

            [ -f "../../summaries/lock-ownership/lo_summary.txt" ] && \
              cp ../../summaries/lock-ownership/lo_summary.txt .

            [ -f "../../summaries/single-threaded/st_summary.txt" ] && \
              cp ../../summaries/single-threaded/st_summary.txt .

            [ -f "../../summaries/escape-analysis-global/ea-logs/ea_summary.txt" ] && \
              cp ../../summaries/escape-analysis-global/ea-logs/ea_summary.txt .

            TSAN_FLAGS=""
            [[ "$OPTION" == *"lo"*   ]] && TSAN_FLAGS="$TSAN_FLAGS -mllvm -tsan-use-lock-ownership"
            [[ "$OPTION" == *"swmr"* ]] && TSAN_FLAGS="$TSAN_FLAGS -mllvm -tsan-use-swmr"
            [[ "$OPTION" == *"st"*   ]] && TSAN_FLAGS="$TSAN_FLAGS -mllvm -tsan-use-single-threaded"
            [[ "$OPTION" == *"ea"*   ]] && TSAN_FLAGS="$TSAN_FLAGS -mllvm -tsan-use-escape-analysis-global"
            [[ "$OPTION" == *"dom"*  ]] && TSAN_FLAGS="$TSAN_FLAGS -mllvm -tsan-use-dominance-analysis"
            
            SANITIZER=thread USE_JEMALLOC=no CFLAGS="$TSAN_FLAGS" make redis-server -j $(nproc) > /dev/null 2>&1
        fi

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
    if [ "$COMPILE" = false ]; then
        log "Switching to polygon directory for tests."
        if [ ! -d "$BENCH_POLYGON_DIR" ]; then
            log "Error: Build directory '$BENCH_POLYGON_DIR' not found. Cannot run tests."
            log "Run the script without --test-only first to create the builds."
            exit 1
        fi
        cd "$BENCH_POLYGON_DIR" || exit
    fi

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
    REQ_LRANGE100=50000
    REQ_LRANGE300=10000
    REQ_LRANGE500=5000
    REQ_LRANGE600=3000
    REQ_MSET=100000

    if [ "$TRACE_MODE" = true ]; then
        log "Reducing benchmark load for trace mode."
        mkdir -p "$TRACES_DIR"

        REQ_GENERAL=$((REQ_GENERAL / 100))
        REQ_LRANGE100=$((REQ_LRANGE100 / 100))
        REQ_LRANGE300=$((REQ_LRANGE300 / 100))
        REQ_LRANGE500=$((REQ_LRANGE500 / 100))
        REQ_LRANGE600=$((REQ_LRANGE600 / 100))
        REQ_MSET=$((REQ_MSET / 100))
    fi

    # --- Benchmark Loop ---
    for OPTION in $BUILD_OPTIONS
    do
        log "Testing $OPTION"
        mkdir -p "$RESULTS_DIR/benchmarks"
        
        if [ "$TRACE_MODE" = true ]; then
            TRACE_FILE="$TRACES_DIR/${OPTION}.trace"
            log "Redirecting trace output to ${TRACE_FILE}.zst"
            "redis-$OPTION/src/redis-server" redis.conf 2>&1 | zstd -1 -o "${TRACE_FILE}.zst" &
        else
            echo -n "$OPTION " >> "$RESULTS_DIR/memory.txt"
            /usr/bin/time --verbose "redis-$OPTION/src/redis-server" redis.conf 2>&1 | grep "Maximum resident set size" | awk '{print $6}' >> "$RESULTS_DIR/memory.txt" &
        fi
        
        sleep 5
        
        # For 'orig' build, append "0" to request count, effectively multiplying it by 10.
        [[ "$OPTION" = "orig" ]] && L="0" || L=""
        
        run "$RESULTS_DIR/benchmarks/$OPTION.txt" PING_INLINE "${REQ_GENERAL}${L}"
        run "$RESULTS_DIR/benchmarks/$OPTION.txt" PING_MBULK  "${REQ_GENERAL}${L}"
        run "$RESULTS_DIR/benchmarks/$OPTION.txt" SET         "${REQ_GENERAL}${L}"
        run "$RESULTS_DIR/benchmarks/$OPTION.txt" GET         "${REQ_GENERAL}${L}"
        run "$RESULTS_DIR/benchmarks/$OPTION.txt" INCR        "${REQ_GENERAL}${L}"
        run "$RESULTS_DIR/benchmarks/$OPTION.txt" LPUSH       "${REQ_GENERAL}${L}"
        run "$RESULTS_DIR/benchmarks/$OPTION.txt" RPUSH       "${REQ_GENERAL}${L}"
        run "$RESULTS_DIR/benchmarks/$OPTION.txt" LPOP        "${REQ_GENERAL}${L}"
        run "$RESULTS_DIR/benchmarks/$OPTION.txt" RPOP        "${REQ_GENERAL}${L}"
        run "$RESULTS_DIR/benchmarks/$OPTION.txt" SADD        "${REQ_GENERAL}${L}"
        run "$RESULTS_DIR/benchmarks/$OPTION.txt" HSET        "${REQ_GENERAL}${L}"
        run "$RESULTS_DIR/benchmarks/$OPTION.txt" SPOP        "${REQ_GENERAL}${L}"
        run "$RESULTS_DIR/benchmarks/$OPTION.txt" ZADD        "${REQ_GENERAL}${L}"
        run "$RESULTS_DIR/benchmarks/$OPTION.txt" ZPOPMIN     "${REQ_GENERAL}${L}"
        run "$RESULTS_DIR/benchmarks/$OPTION.txt" LPUSH       "${REQ_GENERAL}${L}"
        run "$RESULTS_DIR/benchmarks/$OPTION.txt" LRANGE_100  "${REQ_LRANGE100}${L}"
        run "$RESULTS_DIR/benchmarks/$OPTION.txt" LRANGE_300  "${REQ_LRANGE300}${L}"
        run "$RESULTS_DIR/benchmarks/$OPTION.txt" LRANGE_500  "${REQ_LRANGE500}${L}"
        run "$RESULTS_DIR/benchmarks/$OPTION.txt" LRANGE_600  "${REQ_LRANGE600}${L}"
        run "$RESULTS_DIR/benchmarks/$OPTION.txt" MSET        "${REQ_MSET}${L}"
        
        killall -9 redis-server
        sleep 5
        
        rm -f dump.rdb
    done
fi

log "Script finished successfully. All results are in $RESULTS_DIR"