#!/bin/bash
# gen_summaries.sh — whole-program analysis summaries for threadtest3 (sound interface).
# threadtest3 is a single program of three TUs (threadtest3.c, build/sqlite3.c, test_multiplex.c); the
# summaries are produced from their linked, uninstrumented IR with the same flags build_sqlite_test.sh uses.
# Usage:  LLVM_TSAN_ROOT=<frozen copy> [SUMMARY_ID=<tag>] ./gen_summaries.sh [out_dir]
# Output: <out_dir>/{st,lo,ea}_summary.txt (+ PROVENANCE.txt); default out_dir: summaries-<stamp>
# Then:   USE_SUMMARIES=1 SUMMARIES_DIR=<out_dir> BUILD_TAG=-wp ./build_sqlite_test.sh <config>
set -euo pipefail
cd "$(dirname "$0")"
source ../../tools/tsan_compiler.sh
CLANG="$TSAN_CC"; OPT="$TSAN_OPT"; LLVM_LINK="$TSAN_LLVM_ROOT/bin/llvm-link"
for t in "$CLANG" "$OPT" "$LLVM_LINK"; do [ -x "$t" ] || { echo "missing $t"; exit 1; }; done
if [ -f "$TSAN_LLVM_ROOT/TSAN_AUDIT_HASH" ]; then
  HEAD=$(head -1 "$TSAN_LLVM_ROOT/TSAN_AUDIT_HASH" | grep -oE "[0-9a-f]{12}" | head -1)
else
  HEAD=$("$CLANG" --version | grep -oE "[0-9a-f]{40}" | cut -c1-12)
fi
SUMMARY_ID="${SUMMARY_ID:-$HEAD}"
OUT="${1:-summaries-$HEAD}"; [[ "$OUT" = /* ]] || OUT="$PWD/$OUT"
SQLITE_SRC_DIR="sqlite-src-3500200"
eval "$(grep -E '^FLAGS_(TSAN_COMMON|COMMON_BASE)_VAL=' build_sqlite_test.sh)"   # the build's own base flags
FLAGS="$FLAGS_TSAN_COMMON_VAL $FLAGS_COMMON_BASE_VAL -DSQLITE_THREADSAFE=1 -I $SQLITE_SRC_DIR/test/ -I $SQLITE_SRC_DIR/src/"
NOINSTR="-w -mllvm -tsan-instrument-memory-accesses=0 -mllvm -tsan-instrument-func-entry-exit=0 -mllvm -tsan-instrument-atomics=0 -mllvm -tsan-instrument-memintrinsics=0"
WORK=$PWD/sqlite-summaries-work; rm -rf "$WORK"; mkdir -p "$WORK"
echo "compiler: $CLANG ($("$CLANG" --version | head -1)); summary id $SUMMARY_ID"
for src in threadtest3.c build/sqlite3.c "$SQLITE_SRC_DIR/src/test_multiplex.c"; do
  name=$(basename "${src%.c}")
  "$CLANG" $FLAGS $NOINSTR -S -emit-llvm -o "$WORK/$name.ll" "$src"
  grep -q "call.*@__tsan_\(read\|write\|func_entry\)" "$WORK/$name.ll" && { echo "error: instrumentation in $name.ll"; exit 1; }
done
"$LLVM_LINK" -S -o "$WORK/threadtest3.linked.ll" "$WORK"/threadtest3.ll "$WORK"/sqlite3.ll "$WORK"/test_multiplex.ll
echo "linked $(grep -c '^define ' "$WORK/threadtest3.linked.ll") functions"
mkdir -p "$OUT"; cd "$WORK"
for pass in single-threaded lock-ownership escape-analysis-global; do
  "$OPT" -disable-output -passes="print<$pass>" -tsan-use-analysis-summaries -tsan-whole-program \
      -tsan-summary-dir="$OUT" -tsan-summary-id="$SUMMARY_ID" threadtest3.linked.ll > "$pass.print.txt" 2>&1 \
      || { echo "opt print<$pass> failed, see $WORK/$pass.print.txt"; exit 1; }
done
for f in st lo ea; do [ -s "$OUT/${f}_summary.txt" ] || echo "warning: $OUT/${f}_summary.txt missing or empty"; done
cp "$WORK"/*.print.txt "$OUT"/
{
  echo "date: $(date -Iseconds)"
  echo "compiler: $(readlink -f "$CLANG") ($("$CLANG" --version | head -1))"
  echo "compiler_head: $HEAD"; echo "summary_id: $SUMMARY_ID"
  echo "ir_flags: $FLAGS $NOINSTR"
  echo "modules: threadtest3.c build/sqlite3.c test_multiplex.c (linked)"
  echo "opt: -passes=print<single-threaded|lock-ownership|escape-analysis-global> -tsan-use-analysis-summaries -tsan-whole-program -tsan-summary-dir=$OUT -tsan-summary-id=$SUMMARY_ID"
  echo "sizes: $(wc -l "$OUT"/*_summary.txt | tr '\n' ';')"
} > "$OUT/PROVENANCE.txt"
cat "$OUT/PROVENANCE.txt"
echo "summaries written to $OUT/ — build with: USE_SUMMARIES=1 SUMMARIES_DIR=$OUT BUILD_TAG=-wp ./build_sqlite_test.sh <config>"
