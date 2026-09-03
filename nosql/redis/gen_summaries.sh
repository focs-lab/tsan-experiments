#!/bin/bash
# gen_summaries.sh — whole-program analysis summaries for redis-server, hardened-compiler edition.
#
# Replaces the summary block of the paper-era redis.sh (build_single_ll + three
# `opt -passes=print<...> -debug-only=...` runs) for the tsan-dev compiler, where the summary
# mechanism is opt-in (-mllvm -tsan-use-analysis-summaries) and lives in tsan-logs/ of the
# compiler's CWD.
#
# Differences from the paper-era pipeline (kept in redis.sh history for provenance):
#   * The paper-era `summaries/` directory in redis-polygon/ never contained st_/lo_ summaries
#     (only escape-analysis-global/ea-logs/escaping_callees_*.txt), so the paper's optimized
#     Redis builds ran per-TU analyses; the first TU also wrote an empty lo_summary.txt into
#     src/ which every later TU read -> Lock Ownership was a no-op for Redis in the paper.
#   * Modules are emitted WITHOUT TSan instrumentation (the old build_single_ll emitted `.ll`
#     with the instrumentation applied, so every access already carried a __tsan_* call — an
#     external call that makes the pointer escape).  -fsanitize=thread is kept for an
#     identical pipeline; only the instrumentation itself is switched off.
#   * Compile flags are taken from `make -n V=1 redis-server` of the same tarball with the
#     same SANITIZER/USE_JEMALLOC settings as the real build, so the IR the analyses see is
#     built with exactly the flags the binary is built with.
#   * The three analyses run from a clean directory in the order ST -> LO -> EA (LO consumes
#     ST) so that each pass writes its file and later passes may read it.
#
# Usage:  [LLVM_TSAN_ROOT=<llvm/build>] ./gen_summaries.sh [out_dir]
# Output: <out_dir>/{st,lo,ea}_summary.txt + PROVENANCE.txt (default out_dir: summaries-<HEAD>)
# Then:   USE_SUMMARIES=1 SUMMARIES_DIR=<out_dir> BUILD_OPTIONS="sound" ./redis.sh --compile-only
set -euo pipefail
cd "$(dirname "$0")"

# tools/tsan_compiler.sh picks the hardened prototype (focs-lab) unless LLVM_TSAN_ROOT is set;
# $LLVM_ROOT_PATH / $LLVM_PATH from ~/.bashrc point at the unrelated llvm-capstone tree.
source ../../tools/tsan_compiler.sh
CLANG="$TSAN_CC"; OPT="$TSAN_OPT"; LLVM_LINK="$TSAN_LLVM_ROOT/bin/llvm-link"
for t in "$CLANG" "$OPT" "$LLVM_LINK"; do [ -x "$t" ] || { echo "missing $t"; exit 1; }; done
TREE=$(cd "$(dirname "$(readlink -f "$CLANG")")" && while [ ! -e .git ] && [ "$PWD" != / ]; do cd ..; done; pwd)
HEAD=$(git -C "$TREE" rev-parse --short HEAD)
OUT="${1:-summaries-$HEAD}"
[[ "$OUT" = /* ]] || OUT="$PWD/$OUT"
ARCHIVE="${ARCHIVE:-redis-7.0.15.tar.gz}"
[ -f "$ARCHIVE" ] || ARCHIVE="redis-polygon/$(basename "$ARCHIVE")"
[ -f "$ARCHIVE" ] || { echo "archive not found: $ARCHIVE"; exit 1; }
WORK=redis-summaries-work
NPROC=${NPROC:-$(nproc)}
NOINSTR_FLAGS="-w -mllvm -tsan-instrument-memory-accesses=0 -mllvm -tsan-instrument-func-entry-exit=0 \
  -mllvm -tsan-instrument-atomics=0 -mllvm -tsan-instrument-memintrinsics=0"

echo "compiler: $CLANG ($("$CLANG" --version | head -1))"
echo "tree: $TREE branch=$(git -C "$TREE" branch --show-current) head=$HEAD"
echo "ninja: $(ninja -n -C "$TSAN_LLVM_ROOT" 2>/dev/null | tail -1)"

rm -rf "$WORK"; mkdir -p "$WORK"
tar -xzf "$ARCHIVE" -C "$WORK" --strip-components=1
cd "$WORK/src"

# The compile lines the real build would run (same env as redis.sh: SANITIZER=thread,
# USE_JEMALLOC=no, CC=<hardened clang>).  `make -n` executes $(shell ...) hooks such as
# mkreleasehdr.sh, so release.h exists afterwards; deps are only needed for linking.
CC="$CLANG" SANITIZER=thread USE_JEMALLOC=no make -n V=1 redis-server 2>/dev/null \
  | grep -E '^\S*clang\S* .* -o [A-Za-z0-9_.-]+\.o -c [A-Za-z0-9_.-]+\.c$' > compile-lines.txt || true
# (deps/ sub-make lines such as `clang -Wall -Os -g -c linenoise.c` carry no -o and are dropped)
[ -s compile-lines.txt ] || { echo "could not derive compile lines from 'make -n V=1 redis-server'"; exit 1; }
[ -f release.h ] || sh mkreleasehdr.sh > /dev/null
MODULES=$(sed -E 's/.* -c ([A-Za-z0-9_.-]+)\.c$/\1/' compile-lines.txt)
echo "modules ($(wc -l < compile-lines.txt)): $(echo $MODULES | tr '\n' ' ')"

# server.o line -> emit uninstrumented IR: replace "-o X.o -c X.c" by "-S -emit-llvm -o X.ll X.c".
sed -E "s#^(\S*clang\S*) (.*) -o ([A-Za-z0-9_.-]+)\.o -c ([A-Za-z0-9_.-]+)\.c\$#\1 \2 $NOINSTR_FLAGS -S -emit-llvm -o \3.ll \4.c#" \
  compile-lines.txt > emit-lines.txt
echo "emitting IR with the real build flags + $NOINSTR_FLAGS"
xargs -P "$NPROC" -d '\n' -I{} sh -c '{}' < emit-lines.txt
for m in $MODULES; do [ -s "$m.ll" ] || { echo "missing $m.ll"; exit 1; }; done
if grep -l "call.*@__tsan_\(read\|write\|func_entry\)" $(printf '%s.ll ' $MODULES) >/dev/null; then
  echo "error: instrumentation calls present in emitted IR"; exit 1
fi
"$LLVM_LINK" -S -o redis-server.ll $(printf '%s.ll ' $MODULES)
echo "linked $(grep -c '^define ' redis-server.ll) functions into redis-server.ll"

# Run the analyses from a clean directory; with the flag on and no file present each pass
# performs the full analysis and writes tsan-logs/<x>_summary.txt.
rm -rf summarize; mkdir summarize; cd summarize
for pass in single-threaded lock-ownership escape-analysis-global; do
  "$OPT" -disable-output -passes="print<$pass>" -tsan-use-analysis-summaries ../redis-server.ll \
      > "$pass.print.txt" 2>&1 || { echo "opt print<$pass> failed, see $WORK/src/summarize/$pass.print.txt"; exit 1; }
done
ls -l tsan-logs/
for f in st lo ea; do [ -s "tsan-logs/${f}_summary.txt" ] || echo "warning: tsan-logs/${f}_summary.txt missing or empty"; done
cd ../../..

mkdir -p "$OUT"
cp "$WORK"/src/summarize/tsan-logs/*_summary.txt "$OUT"/
cp "$WORK"/src/summarize/*.print.txt "$OUT"/
cp "$WORK"/src/compile-lines.txt "$OUT"/
{
  echo "date: $(date -Iseconds)"
  echo "compiler: $(readlink -f "$CLANG") ($("$CLANG" --version | head -1))"
  echo "tree: $TREE branch=$(git -C "$TREE" branch --show-current) head=$(git -C "$TREE" rev-parse HEAD) dirty=$(git -C "$TREE" status --porcelain --untracked-files=no | wc -l)"
  echo "archive: $ARCHIVE ($(md5sum "$ARCHIVE" | cut -c1-8))"
  echo "ir_flags: real compile lines (compile-lines.txt) + $NOINSTR_FLAGS"
  echo "modules: $(echo $MODULES | tr '\n' ' ')"
  echo "opt: -passes=print<single-threaded|lock-ownership|escape-analysis-global> -tsan-use-analysis-summaries (ST -> LO -> EA, clean dir)"
  echo "sizes: $(wc -l "$OUT"/*_summary.txt | tr '\n' ';')"
} > "$OUT/PROVENANCE.txt"
cat "$OUT/PROVENANCE.txt"
echo "summaries written to $OUT/ — build with: USE_SUMMARIES=1 SUMMARIES_DIR=$OUT BUILD_OPTIONS=\"sound\" ./redis.sh --compile-only"
