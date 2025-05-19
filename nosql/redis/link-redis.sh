#!/bin/sh

export LLVM_BUILD_DIR="/home/somebody/llvm-project/build-release-disable-instr"
export PATH="$LLVM_BUILD_DIR/bin:$PATH"

make distclean
rm -f *.ll

# Building dependencies
CC=clang CXX=clang++ SANITIZER=thread USE_JEMALLOC=no make -j $(nproc)

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
        -DHAVE_LIBSYSTEMD -MMD -S -emit-llvm -o "$MODULE.ll" "$MODULE.c"
done

llvm-link -S -o redis-server.ll *.ll

# Linking the libclang_rt.tsan.a causes segmentation fault during runtime,
# so using -fsanitize=thread (with duplicated TSan calls)
# Also add -O2 flag, which is important when compiling from IR
clang -fsanitize=thread -O2 -g -ggdb -rdynamic -o redis-server redis-server.ll \
    ../deps/hiredis/libhiredis.a \
    ../deps/lua/src/liblua.a \
    ../deps/hdr_histogram/libhdrhistogram.a \
    -lm -ldl -pthread -lrt -lsystemd
