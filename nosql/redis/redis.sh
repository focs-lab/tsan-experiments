#!/bin/bash

# LLVM_BUILD_DIR="/home/somebody/llvm-project/build-release"

# BENCH_ARCHIVE_URL="https://download.redis.io/releases/redis-7.0.15.tar.gz"
BENCH_ARCHIVE_URL="https://github.com/redis/redis/archive/refs/tags/7.0.15.tar.gz"
BENCH_POLYGON_DIR="/dev/shm/redis-polygon"

BENCH_ARCHIVE_NAME=`basename "$BENCH_ARCHIVE_URL"`
SCRIPT_DIR=$(dirname $(realpath -s "$0"))

# List of all build variants
#BUILD_OPTIONS="orig tsan dom ea dom-ea lo dom-lo ea-lo dom-ea-lo \
#    st dom-st ea-st dom-ea-st lo-st dom-lo-st ea-lo-st dom-ea-lo-st \
#    swmr dom-swmr ea-swmr dom-ea-swmr lo-swmr dom-lo-swmr ea-lo-swmr \
#    dom-ea-lo-swmr st-swmr dom-st-swmr ea-st-swmr dom-ea-st-swmr \
#    lo-st-swmr dom-lo-st-swmr ea-lo-st-swmr dom-ea-lo-st-swmr"
BUILD_OPTIONS="dom-ea-lo-st-swmr"

# List of benchmark tests
#BENCHMARK_TESTS="PING_INLINE PING_MBULK SET GET INCR LPUSH RPUSH LPOP RPOP \
#    SADD HSET SPOP ZADD ZPOPMIN LPUSH LRANGE_100 LRANGE_300 LRANGE_500 LRANGE_600 MSET"

[ -z "$LLVM_BUILD_DIR" ] && { echo -e "No LLVM_BUILD_DIR set\n  Example: /home/user/llvm-project/build-release"; exit 1; }

export PATH="$LLVM_BUILD_DIR/bin:$PATH"
export CC=clang
export CXX=clang++
export LC_ALL=en_US.UTF-8
export TIMEFORMAT="%E"

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
        -n $REQUESTS \
        -t $TEST | grep throughput | tail -1 | awk '{print $3}' | tee -a "$FILE"
}

CC=clang
CXX=clang++

set -e

echo "Creating Redis polygon"
rm -rf "$BENCH_POLYGON_DIR"
mkdir "$BENCH_POLYGON_DIR"

echo "Downloading Redis"
cd "$BENCH_POLYGON_DIR"
wget "$BENCH_ARCHIVE_URL" 2> /dev/null
BENCH_ARCHIVE_DIR=`tar --list --file "$BENCH_ARCHIVE_NAME" | head -1`

echo "Unpacking redis-benchmark"
tar --extract --file "$BENCH_ARCHIVE_NAME"
mv "$BENCH_ARCHIVE_DIR" redis-benchmark

echo "Building redis-benchmark"
cd redis-benchmark/src
make -j $(nproc) redis-benchmark > /dev/null 2>&1
cd ../..

if [[ -d "$SCRIPT_DIR/summaries" ]]
then
    echo "Ready summaries found"
    cp -r "$SCRIPT_DIR/summaries" .
else
    echo "Building a single LL"
    tar --extract --file "$BENCH_ARCHIVE_NAME"
    mv "$BENCH_ARCHIVE_DIR" redis-single-ll
    cd redis-single-ll/src
    build_single_ll
    cd ../..

    echo "Building summaries (may take a long time)"
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

mkdir results

for OPTION in $BUILD_OPTIONS
do
    echo -n "Building $OPTION... "
    echo -n "$OPTION " >> results/compile.txt
    tar --extract --file "$BENCH_ARCHIVE_NAME"
    mv "$BENCH_ARCHIVE_DIR" "redis-$OPTION"
    cd "redis-$OPTION"/src

    if [[ "$OPTION" = "orig" ]]
    then
        { time USE_JEMALLOC=no make redis-server -j $(nproc) > /dev/null 2>&1; } |& tee -a ../../results/compile.txt
    elif [[ "$OPTION" = "tsan" ]]
    then
        { time SANITIZER=thread USE_JEMALLOC=no make redis-server -j $(nproc) > /dev/null 2>&1; } |& tee -a ../../results/compile.txt
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
        
        { time SANITIZER=thread USE_JEMALLOC=no CFLAGS="$TSAN_FLAGS" make redis-server -j $(nproc) > /dev/null 2>&1; } |& tee -a ../../results/compile.txt
    fi
    
    cd ../..
done

cp -r "$SCRIPT_DIR/redis.conf" .

for OPTION in $BUILD_OPTIONS
do

    echo "Testing $OPTION"
    echo -n "$OPTION " >> results/memory.txt
    /usr/bin/time --verbose "redis-$OPTION/src/redis-server" redis.conf |& grep Maximum | awk '{print $6}' >> results/memory.txt &
    
    sleep 5
    
    [[ "$OPTION" = "orig" ]] && L="0" || L=""
    
    run "results/$OPTION.txt" PING_INLINE 1000000$L
    run "results/$OPTION.txt" PING_MBULK  1000000$L
    run "results/$OPTION.txt" SET         1000000$L
    run "results/$OPTION.txt" GET         1000000$L
    run "results/$OPTION.txt" INCR        1000000$L
    run "results/$OPTION.txt" LPUSH       1000000$L
    run "results/$OPTION.txt" RPUSH       1000000$L
    run "results/$OPTION.txt" LPOP        1000000$L
    run "results/$OPTION.txt" RPOP        1000000$L
    run "results/$OPTION.txt" SADD        1000000$L
    run "results/$OPTION.txt" HSET        1000000$L
    run "results/$OPTION.txt" SPOP        1000000$L
    run "results/$OPTION.txt" ZADD        1000000$L
    run "results/$OPTION.txt" ZPOPMIN     1000000$L
    run "results/$OPTION.txt" LPUSH       1000000$L
    run "results/$OPTION.txt" LRANGE_100  50000$L
    run "results/$OPTION.txt" LRANGE_300  10000$L
    run "results/$OPTION.txt" LRANGE_500  5000$L
    run "results/$OPTION.txt" LRANGE_600  3000$L
    run "results/$OPTION.txt" MSET        100000$L
    
    killall -9 redis-server
    sleep 5
    
    rm -f dump.rdb
    
done
