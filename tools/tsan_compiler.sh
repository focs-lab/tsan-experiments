#!/bin/bash
# tsan_compiler.sh — pick the TSan prototype compiler for the experiment build scripts.
#
#   source "<repo>/tools/tsan_compiler.sh"     # sets TSAN_LLVM_ROOT, TSAN_CC, TSAN_CXX, TSAN_OPT
#
# Priority: $LLVM_TSAN_ROOT (explicit) > $LLVM_ROOT_PATH if it really is a focs-lab TSan tree >
# the default focs-lab build.  ~/.bashrc exports LLVM_ROOT_PATH=~/dev/llvm-project/llvm/build,
# which since 2026-05 is a symlink to the unrelated llvm-capstone tree, so that value is verified
# instead of trusted.
TSAN_LLVM_DEFAULT=/home/alexey/dev/llvm-project-focs-lab/llvm/build
_tsan_is_prototype() { [ -x "$1/bin/clang" ] && "$1/bin/clang" --version 2>/dev/null | grep -qE "focs-lab/llvm-project|llvm-project-focs-lab"; }  # GitHub origin or a local clone of it (e.g. /extra/alexey/llvm-project-paper)
# `set -u`-safe: callers such as gen_summaries.sh run with nounset.
if [ -n "${LLVM_TSAN_ROOT:-}" ]; then
  TSAN_LLVM_ROOT="$LLVM_TSAN_ROOT"
elif [ -n "${LLVM_ROOT_PATH:-}" ] && _tsan_is_prototype "$LLVM_ROOT_PATH"; then
  TSAN_LLVM_ROOT="$LLVM_ROOT_PATH"
else
  [ -n "${LLVM_ROOT_PATH:-}" ] && echo "tsan_compiler.sh: ignoring LLVM_ROOT_PATH=$LLVM_ROOT_PATH (not the TSan prototype tree)" >&2
  TSAN_LLVM_ROOT="$TSAN_LLVM_DEFAULT"
fi
_tsan_is_prototype "$TSAN_LLVM_ROOT" || { echo "tsan_compiler.sh: $TSAN_LLVM_ROOT/bin/clang is not the focs-lab TSan prototype" >&2; return 1 2>/dev/null || exit 1; }
export TSAN_LLVM_ROOT TSAN_CC="$TSAN_LLVM_ROOT/bin/clang" TSAN_CXX="$TSAN_LLVM_ROOT/bin/clang++" TSAN_OPT="$TSAN_LLVM_ROOT/bin/opt"
echo "tsan_compiler.sh: using $TSAN_CC ($("$TSAN_CC" --version | head -1))" >&2
