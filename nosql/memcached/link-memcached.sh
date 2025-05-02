#!/bin/sh
set -e

BUILD_TYPE=tsan

# Build script for memcached with ThreadSanitizer
# Requires LLVM_PATH environment variable to be set

if [ -z "$LLVM_PATH" ]; then
    echo "Error: LLVM_PATH environment variable is not set"
    exit 1
fi

export LLVM_BUILD_DIR="$LLVM_PATH"
export PATH="$LLVM_BUILD_DIR/bin:$PATH"

cleanup() {
    echo "Cleaning up temporary files..."
    rm -f *.ll
}

#trap cleanup EXIT
cleanup

echo "Setting up build environment..."
CC=clang

echo "Running configure..."
./configure || {
    echo "Configure failed"
    exit 1
}

COMMON_FLAGS="-DHAVE_CONFIG_H -I. -DNDEBUG -O2 -g"
if [ "$BUILD_TYPE" = "tsan" ]; then
    COMMON_FLAGS="$COMMON_FLAGS -fsanitize=thread"
fi

compile_module() {
    local module=$1
#    echo "Compiling module: $module"
    clang $COMMON_FLAGS -S -emit-llvm -MT "memcached-$module.o" \
        -MD -MP -MF ".deps/memcached-$module.Tpo" -c -o "memcached-$module.ll" "$module.c"
}

MODULES="memcached hash jenkins_hash murmur3_hash slabs items assoc thread \
         daemon stats_prefix util cache bipbuffer base64 logger crawler itoa_ljust \
         slab_automove authfile restart proto_text proto_bin extstore crc32c storage \
         slab_automove_extstore"

echo "Compiling individual modules..."
for MODULE in $MODULES; do
    compile_module "$MODULE" || {
        echo "Failed to compile module: $MODULE"
        exit 1
    }
done

echo "Linking modules..."
llvm-link -S -o memcached.ll *.ll || {
    echo "Linking failed"
    exit 1
}

echo "Building final executable..."
clang -o memcached memcached.ll $COMMON_FLAGS \
    -levent "$LLVM_BUILD_DIR/lib/clang/19/lib/x86_64-unknown-linux-gnu/libclang_rt.tsan.a" -lm || {
  echo "Final build failed"
  exit 1
}

echo "Build completed successfully"
