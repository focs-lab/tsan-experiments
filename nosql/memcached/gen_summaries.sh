#!/bin/bash
# gen_summaries.sh — whole-program analysis summaries for memcached, hardened-compiler edition.
#
# Replaces the paper-era pair llvm-link-memcached.sh + build_summaries.sh for the
# tsan-dev compiler, where the summary mechanism is opt-in (-mllvm -tsan-use-analysis-summaries)
# and lives in tsan-logs/ of the compiler's CWD.
#
# Differences from the paper-era pipeline (kept for provenance, do not use with tsan-dev):
#   * Modules are emitted WITHOUT TSan instrumentation (the old scripts emitted `.ll`
#     with -fsanitize=thread, i.e. every access already carried a __tsan_* call — an
#     external call that makes the pointer escape, so the old EA summary contained no
#     pointer arguments at all).  We keep -fsanitize=thread for an identical pipeline and
#     turn off the instrumentation itself.
#   * The three analyses are run from a clean directory in the order ST -> LO -> EA
#     (LO consumes ST) so that each pass writes its file and later passes may read it.
#
# Usage:  [LLVM_TSAN_ROOT=<llvm/build>] ./gen_summaries.sh [out_dir]
# Output: <out_dir>/{st,lo,ea}_summary.txt + PROVENANCE.txt (default out_dir: summaries-<HEAD>)
# Then:   USE_SUMMARIES=1 SUMMARIES_DIR=<out_dir> ./build_memcached.sh tsan-sound
set -euo pipefail
cd "$(dirname "$0")"

# tools/tsan_compiler.sh picks the hardened prototype (focs-lab) unless LLVM_TSAN_ROOT is set;
# $LLVM_ROOT_PATH / $LLVM_PATH from ~/.bashrc point at the unrelated llvm-capstone tree.
source ../../tools/tsan_compiler.sh
CLANG="$TSAN_CC"; OPT="$TSAN_OPT"; LLVM_LINK="$TSAN_LLVM_ROOT/bin/llvm-link"
for t in "$CLANG" "$OPT" "$LLVM_LINK"; do [ -x "$t" ] || { echo "missing $t"; exit 1; }; done
# Frozen per-hash copies (/extra/alexey/builds/<name>/) are not git trees: take the id from TSAN_AUDIT_HASH or the version string.
if [ -f "$TSAN_LLVM_ROOT/TSAN_AUDIT_HASH" ]; then
  TREE="$TSAN_LLVM_ROOT"; HEAD=$(head -1 "$TSAN_LLVM_ROOT/TSAN_AUDIT_HASH" | grep -oE "[0-9a-f]{12}" | head -1)
else
  TREE=$(cd "$(dirname "$(readlink -f "$CLANG")")" && while [ ! -e .git ] && [ "$PWD" != / ]; do cd ..; done; pwd)
  HEAD=$(git -C "$TREE" rev-parse --short HEAD 2>/dev/null || "$CLANG" --version | grep -oE "[0-9a-f]{40}" | cut -c1-12)
fi
OUT="${1:-summaries-$HEAD}"
[[ "$OUT" = /* ]] || OUT="$PWD/$OUT"
ARCHIVE=memcached-1.6.29.tar.gz
WORK=memcached-summaries-work
NPROC=${NPROC:-$(nproc)}

echo "compiler: $CLANG ($("$CLANG" --version | head -1))"
echo "tree: $TREE branch=$(git -C "$TREE" branch --show-current) head=$HEAD"
echo "ninja: $(ninja -n -C "$LLVM_TSAN_ROOT" 2>/dev/null | tail -1)"

rm -rf "$WORK"; mkdir -p "$WORK"
tar -xzf "$ARCHIVE" -C "$WORK" --strip-components=1
cd "$WORK"
CC="$CLANG" CFLAGS="-O2 -g" ./configure --prefix="$PWD" > configure.log 2>&1

# Same modules the real build links (memcached_SOURCES for this configure).
MODULES=$(make -n memcached 2>/dev/null | grep -o 'memcached-[a-z0-9_]*\.o' | sort -u | sed 's/^memcached-//; s/\.o$//')
[ -n "$MODULES" ] || { echo "could not derive module list from 'make -n memcached'"; exit 1; }
echo "modules: $(echo $MODULES | tr '\n' ' ')"

COMMON_FLAGS="-DHAVE_CONFIG_H -I. -DNDEBUG -O2 -g -fsanitize=thread \
  -mllvm -tsan-instrument-memory-accesses=0 -mllvm -tsan-instrument-func-entry-exit=0 \
  -mllvm -tsan-instrument-atomics=0 -mllvm -tsan-instrument-memintrinsics=0"
echo "emitting IR with: $COMMON_FLAGS"
printf '%s\n' $MODULES | xargs -P "$NPROC" -I{} sh -c "$CLANG $COMMON_FLAGS -S -emit-llvm -o memcached-{}.ll {}.c"
if grep -l "call.*@__tsan_\(read\|write\|func_entry\)" memcached-*.ll >/dev/null; then
  echo "error: instrumentation calls present in emitted IR"; exit 1
fi
"$LLVM_LINK" -S -o memcached.ll $(printf 'memcached-%s.ll ' $MODULES)
echo "linked $(grep -c '^define ' memcached.ll) functions into memcached.ll"

# Run the analyses from a clean directory; with the flag on and no file present each pass
# performs the full analysis and writes tsan-logs/<x>_summary.txt.
# Sound summaries interface (tsan-audit fafbebedb41e+): the linked-IR run gets -tsan-whole-program (asserts that
# nothing outside the module calls in except through taken addresses and main), writes to -tsan-summary-dir and
# tags every file with -tsan-summary-id; per-TU compiles pass the same dir/id (build_memcached.sh, USE_SUMMARIES=1).
SUMMARY_ID="${SUMMARY_ID:-$HEAD}"
rm -rf summarize; mkdir summarize; cd summarize
mkdir -p "$OUT"
for pass in single-threaded lock-ownership escape-analysis-global; do
  "$OPT" -disable-output -passes="print<$pass>" -tsan-use-analysis-summaries -tsan-whole-program \
      -tsan-summary-dir="$OUT" -tsan-summary-id="$SUMMARY_ID" ../memcached.ll \
      > "$pass.print.txt" 2>&1 || { echo "opt print<$pass> failed, see $WORK/summarize/$pass.print.txt"; exit 1; }
done
ls -l "$OUT"
for f in st lo ea; do [ -s "$OUT/${f}_summary.txt" ] || echo "warning: $OUT/${f}_summary.txt missing or empty"; done
cd ../..
cp "$WORK"/summarize/*.print.txt "$OUT"/
{
  echo "date: $(date -Iseconds)"
  echo "compiler: $(readlink -f "$CLANG") ($("$CLANG" --version | head -1))"
  echo "tree: $TREE head=$HEAD $(git -C "$TREE" branch --show-current 2>/dev/null | sed 's/^/branch=/')"
  echo "ir_flags: $COMMON_FLAGS"
  echo "modules: $(echo $MODULES | tr '\n' ' ')"
  echo "opt: -passes=print<single-threaded|lock-ownership|escape-analysis-global> -tsan-use-analysis-summaries -tsan-whole-program -tsan-summary-dir=$OUT -tsan-summary-id=$SUMMARY_ID (ST -> LO -> EA)"
  echo "summary_id: $SUMMARY_ID"
  echo "sizes: $(wc -l "$OUT"/*_summary.txt | tr '\n' ';')"
} > "$OUT/PROVENANCE.txt"
cat "$OUT/PROVENANCE.txt"
echo "summaries written to $OUT/ — build with: USE_SUMMARIES=1 SUMMARIES_DIR=$OUT ./build_memcached.sh <config>"
