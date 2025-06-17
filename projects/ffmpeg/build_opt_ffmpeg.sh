#!/bin/bash

[ -z "$1" ] && echo "Usage: $0 <large-single-file-to-optimize-with-tsan-special.ll>" && exit 1

[ ! -f "$LLVM_ROOT_PATH/bin/opt" ] && echo "No $LLVM_ROOT_PATH/bin/opt here (\$LLVM_ROOT_PATH: '$LLVM_ROOT_PATH')." && exit 2


# To obtain single-linked files like "ffmpeg_g.0.0.preopt.bc", you must use these flags when building the project:
#
#	--extra-cflags="$FINAL_CFLAGS -flto -opaque-pointers" \
#	--extra-cxxflags="$FINAL_CFLAGS  -flto -opaque-pointers" \
#	--extra-ldflags="$FINAL_CFLAGS -flto -fuse-ld=lld -Wl,--save-temps,--verbose" \
#

echo Lock Ownership
$LLVM_ROOT_PATH/bin/opt -S -disable-output -passes='print<lock-ownership>' -debug-only=lock-ownership "$1" 2>&1 | pv > llvm-opt_lockown.stderr.log

echo EA IPA
$LLVM_ROOT_PATH/bin/opt -S -disable-output -passes='print<escape-analysis-global>' -debug-only=ea-escaping-callees "$1" 2>&1 | pv > llvm-opt_ea.stderr.log

echo Single-threaded
$LLVM_ROOT_PATH/bin/opt -S -disable-output -passes='print<single-threaded>' -debug-only=single-threaded "$1" 2>&1 | pv > llvm-opt_st.stderr.log
