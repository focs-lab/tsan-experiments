#!/bin/bash
# gen_summaries.sh — whole-program analysis summaries for threadtest3 (sound interface).
# threadtest3 is a single program of three TUs (threadtest3.c, build/sqlite3.c, test_multiplex.c); the
# summaries are produced from their linked, uninstrumented IR with the same flags build_sqlite_test.sh uses.
# Usage:  LLVM_TSAN_ROOT=<frozen copy> [SUMMARY_ID=<tag>] ./gen_summaries.sh [out_dir]
# Output: <out_dir>/{st,lo,ea}_summary.txt (+ PROVENANCE.txt); default out_dir: summaries-<stamp>
# Then:   USE_SUMMARIES=1 SUMMARIES_DIR=<out_dir> BUILD_TAG=-wp ./build_sqlite_test.sh <config>
set -euo pipefail
# Which generator produced a summary: its own sha256 goes into PROVENANCE (26 Sep 2026: generators changed between builds).
GEN_SHA=$(sha256sum < "${BASH_SOURCE[0]}" | cut -c1-16); GEN_NAME="$(basename "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/gen_summaries.sh"   # before any cd
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
# Never write into an existing, non-empty summary dir: the reader's id check ignores the flags and the list, so old files
# there would be reused silently (audit A13, H3).
if [ -d "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then echo "error: $OUT exists and is not empty; remove it or pass another dir"; exit 1; fi
# The leg's lever flags must reach the whole-program pass as well as the per-unit compiles: a rule that runs only under
# -tsan-whole-program (U1's, SingleThreaded.cpp) never saw them before 26 Sep 2026, and U1 measured nothing.
EXTRA_OPT=$(echo " ${TSAN_EXTRA_MLLVM:-} " | sed -E 's/ -mllvm / /g')
SQLITE_SRC_DIR="sqlite-src-3500200"
eval "$(grep -E '^FLAGS_(TSAN_COMMON|COMMON_BASE)_VAL=' build_sqlite_test.sh)"   # the build's own base flags
# -I build/ COMES FIRST, for the same reason build_sqlite_test.sh:131 gives: threadtest3.c includes
# <sqlite3.h> with angle brackets, the amalgamation writes that header into build/ beside sqlite3.c, and
# without the -I the compile falls through to whatever /usr/include holds. On this host libsqlite3-dev
# supplied one and the generator worked; on a host without it the summaries step dies with
# "threadtest3.c:80:10: fatal error: 'sqlite3.h' file not found" after building twelve configurations.
# The build script was fixed on 17 Sep and the SUMMARIES GENERATOR, which compiles the same sources with
# the same flags, was not. (An external rehearsal run of `evaluate.sh everything`, 22 Sep 2026.)
FLAGS="$FLAGS_TSAN_COMMON_VAL $FLAGS_COMMON_BASE_VAL -DSQLITE_THREADSAFE=1 -I build/ -I $SQLITE_SRC_DIR/test/ -I $SQLITE_SRC_DIR/src/"
NOINSTR="-w -mllvm -tsan-instrument-memory-accesses=0 -mllvm -tsan-instrument-func-entry-exit=0 -mllvm -tsan-instrument-atomics=0 -mllvm -tsan-instrument-memintrinsics=0"
# THE SOURCES FIRST. The amalgamation (build/sqlite3.c) and the source tree are made by the plain build
# (build.sh runs download_and_compile_sqlite.sh when either is absent); a -wp build in a fresh tree calls this
# generator before any plain build has run, and on 25 Sep 2026 died with "no such file or directory:
# 'build/sqlite3.c'" (U1 of U-CEIL). Prepare them here too, under the same condition build.sh uses.
if [ ! -f build/sqlite3.c ] || [ ! -d "$SQLITE_SRC_DIR" ]; then ./download_and_compile_sqlite.sh || exit 1; fi
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
# Explicit list (the -tsan-external-symbols rule, audit A13): the undefined symbols of every object linked into the
# program without IR. threadtest3's three units are all in the linked IR and it links nothing else but the system
# libraries (which reach it only through pointers it hands them), so the list is the header alone.
echo "# tsan-external-symbols v1" > "$OUT/external-symbols.txt"
OPT_ARGS=(-tsan-use-analysis-summaries -tsan-whole-program -tsan-summary-dir="$OUT" -tsan-summary-id="$SUMMARY_ID" $EXTRA_OPT)
"$OPT" --help-hidden 2>/dev/null | grep -c -- '-tsan-external-symbols' > /dev/null && OPT_ARGS+=(-tsan-external-symbols="$OUT/external-symbols.txt")
# require<> by default: the analyses write their summary files themselves; print<> only adds a textual dump of the result
# (FFmpeg's EA dump ran for over 2 h on 26 Sep; require<> wrote a byte-identical ea_summary.txt in 35 s - a control run).
# GEN_PASS_MODE=print restores the dump.
MODE=${GEN_PASS_MODE:-require}; case "$MODE" in require|print) ;; *) echo "error: GEN_PASS_MODE must be require or print"; exit 1;; esac
for pass in single-threaded lock-ownership escape-analysis-global; do
  "$OPT" -disable-output -passes="$MODE<$pass>" "${OPT_ARGS[@]}" threadtest3.linked.ll > "$pass.$MODE.txt" 2>&1 \
      || { echo "opt $MODE<$pass> failed, see $WORK/$pass.$MODE.txt"; exit 1; }
done
for f in st lo ea; do [ -s "$OUT/${f}_summary.txt" ] || echo "warning: $OUT/${f}_summary.txt missing or empty"; done
cp "$WORK"/*."$MODE".txt "$OUT"/
{
  echo "date: $(date -Iseconds)"
  echo "generator: $GEN_NAME sha256 $GEN_SHA"
  echo "compiler: $(readlink -f "$CLANG") ($("$CLANG" --version | head -1))"
  echo "compiler_head: $HEAD"; echo "summary_id: $SUMMARY_ID"
  echo "ir_flags: $FLAGS $NOINSTR"
  echo "modules: threadtest3.c build/sqlite3.c test_multiplex.c (linked)"
  echo "opt: -passes=$MODE<single-threaded|lock-ownership|escape-analysis-global> ${OPT_ARGS[*]}"   # the arguments actually passed
  echo "sizes: $(wc -l "$OUT"/*_summary.txt | tr '\n' ';')"
} > "$OUT/PROVENANCE.txt"
cat "$OUT/PROVENANCE.txt"
echo "summaries written to $OUT/ — build with: USE_SUMMARIES=1 SUMMARIES_DIR=$OUT BUILD_TAG=-wp ./build_sqlite_test.sh <config>"
