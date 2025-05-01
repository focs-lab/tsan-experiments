#!/bin/sh

export LLVM_BUILD_DIR="/path/to/build-release-disable-instr"
export PATH="$LLVM_BUILD_DIR/bin:$PATH"

rm -f *.ll

CC=clang ./configure

for MODULE in "memcached" "hash" "jenkins_hash" "murmur3_hash" "slabs" "items" "assoc" "thread" \
              "daemon" "stats_prefix" "util" "cache" "bipbuffer" "base64" "logger" "crawler" "itoa_ljust" \
              "slab_automove" "authfile" "restart" "proto_text" "proto_bin" "extstore" "crc32c" "storage" \
              "slab_automove_extstore"
do
    clang -DHAVE_CONFIG_H -I. -DNDEBUG -O2 -fsanitize=thread -g -S -emit-llvm -MT "memcached-$MODULE.o" \
        -MD -MP -MF ".deps/memcached-$MODULE.Tpo" -c -o "memcached-$MODULE.ll" "$MODULE.c"
done

llvm-link -S -o memcached.ll *.ll

clang -o memcached memcached.ll -O2 -g -levent "$LLVM_BUILD_DIR/lib/clang/19/lib/x86_64-unknown-linux-gnu/libclang_rt.tsan.a" -lm
