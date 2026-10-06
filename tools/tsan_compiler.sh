#!/bin/bash
# tsan_compiler.sh — pick the TSan prototype compiler for the experiment build scripts.
#
#   source "<repo>/tools/tsan_compiler.sh"     # sets TSAN_LLVM_ROOT, TSAN_CC, TSAN_CXX, TSAN_OPT
#
# Priority: $LLVM_TSAN_ROOT (explicit) > $LLVM_ROOT_PATH if it really is a prototype TSan tree >
# the default prototype build.  A shell profile may export LLVM_ROOT_PATH at an unrelated tree,
# which since 2026-05 is a symlink to the unrelated llvm-capstone tree, so that value is verified
# instead of trusted.
TSAN_LLVM_DEFAULT="${TSAN_LLVM_DEFAULT:-$HOME/dev/llvm-project-focs-lab/llvm/build}"
# WHAT MAKES A COMPILER THE PROTOTYPE IS THE FLAGS IT ACCEPTS, NOT THE URL IT PRINTS. This tested
# --version for the prototype's own string, which the container satisfies only because the Dockerfile forces
# that string -- so a reviewer who builds the patched LLVM themselves, which the artifact tells them they
# may, had every application build refused for a reason they could not act on. The version string stays as
# the fast path because it is true of our own builds; a compiler that fails it is now asked whether it
# understands a prototype flag, which is the property the harness actually needs. (Audit, 2026-09-19.)
_tsan_probe_flag="${TSAN_PROBE_FLAG:--tsan-use-dominance-analysis}"
_tsan_accepts_flag() {
  [ -x "$1/bin/clang" ] || return 1
  echo 'int main(void){return 0;}' | "$1/bin/clang" -x c - -fsanitize=thread \
      -mllvm "$_tsan_probe_flag" -o /dev/null 2>/dev/null
}
_tsan_is_prototype() {
  [ -x "$1/bin/clang" ] || return 1
  "$1/bin/clang" --version 2>/dev/null | grep -qE "focs-lab/llvm-project|llvm-project-focs-lab" && return 0
  _tsan_accepts_flag "$1"
}
# `set -u`-safe: callers such as gen_summaries.sh run with nounset.
if [ -n "${LLVM_TSAN_ROOT:-}" ]; then
  TSAN_LLVM_ROOT="$LLVM_TSAN_ROOT"
elif [ -n "${LLVM_ROOT_PATH:-}" ] && _tsan_is_prototype "$LLVM_ROOT_PATH"; then
  TSAN_LLVM_ROOT="$LLVM_ROOT_PATH"
else
  [ -n "${LLVM_ROOT_PATH:-}" ] && echo "tsan_compiler.sh: ignoring LLVM_ROOT_PATH=$LLVM_ROOT_PATH (not the TSan prototype tree)" >&2
  TSAN_LLVM_ROOT="$TSAN_LLVM_DEFAULT"
fi
_tsan_is_prototype "$TSAN_LLVM_ROOT" || { echo "tsan_compiler.sh: $TSAN_LLVM_ROOT/bin/clang is not the TSan prototype: its --version does not name focs-lab/llvm-project AND it rejects -mllvm $_tsan_probe_flag." >&2; echo "  A self-built patched LLVM is fine -- it only has to accept that flag." >&2; return 1 2>/dev/null || exit 1; }
export TSAN_LLVM_ROOT TSAN_CC="$TSAN_LLVM_ROOT/bin/clang" TSAN_CXX="$TSAN_LLVM_ROOT/bin/clang++" TSAN_OPT="$TSAN_LLVM_ROOT/bin/opt"
echo "tsan_compiler.sh: using $TSAN_CC ($("$TSAN_CC" --version | head -1))$([ -f "$TSAN_LLVM_ROOT/TSAN_AUDIT_HASH" ] && echo " [frozen copy, TSAN_AUDIT_HASH=$(head -1 "$TSAN_LLVM_ROOT/TSAN_AUDIT_HASH" | cut -c1-12)]")" >&2
