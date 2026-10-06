#!/bin/bash
# gen_summaries.sh — whole-program analysis summaries for memcached, hardened-compiler edition.
#
# Replaces the paper-era pair llvm-link-memcached.sh + build_summaries.sh for the
# prototype compiler, where the summary mechanism is opt-in (-mllvm -tsan-use-analysis-summaries)
# and lives in tsan-logs/ of the compiler's CWD.
#
# Differences from the paper-era pipeline (kept for provenance, do not use with the prototype):
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
# Which generator produced a summary: its own sha256 goes into PROVENANCE (26 Sep 2026: generators changed between builds).
GEN_SHA=$(sha256sum < "${BASH_SOURCE[0]}" | cut -c1-16); GEN_NAME="$(basename "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/gen_summaries.sh"   # before any cd
cd "$(dirname "$0")"

# tools/tsan_compiler.sh picks the hardened prototype unless LLVM_TSAN_ROOT is set;
# $LLVM_ROOT_PATH / $LLVM_PATH from ~/.bashrc point at the unrelated llvm-capstone tree.
source ../../tools/tsan_compiler.sh
CLANG="$TSAN_CC"; OPT="$TSAN_OPT"; LLVM_LINK="$TSAN_LLVM_ROOT/bin/llvm-link"
for t in "$CLANG" "$OPT" "$LLVM_LINK"; do [ -x "$t" ] || { echo "missing $t"; exit 1; }; done
# Frozen per-hash copies (a frozen per-hash copy) are not git trees: take the id from TSAN_AUDIT_HASH or the version string.
if [ -f "$TSAN_LLVM_ROOT/TSAN_AUDIT_HASH" ]; then
  TREE="$TSAN_LLVM_ROOT"; HEAD=$(head -1 "$TSAN_LLVM_ROOT/TSAN_AUDIT_HASH" | grep -oE "[0-9a-f]{12}" | head -1)
else
  TREE=$(cd "$(dirname "$(readlink -f "$CLANG")")" && while [ ! -e .git ] && [ "$PWD" != / ]; do cd ..; done; pwd)
  HEAD=$(git -C "$TREE" rev-parse --short HEAD 2>/dev/null || "$CLANG" --version | grep -oE "[0-9a-f]{40}" | cut -c1-12)
fi
OUT="${1:-summaries-$HEAD}"
[[ "$OUT" = /* ]] || OUT="$PWD/$OUT"
# Never write into an existing, non-empty summary dir: the reader's id check ignores the flags and the list, so old files
# there would be reused silently (audit A13, H3).
if [ -d "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then echo "error: $OUT exists and is not empty; remove it or pass another dir"; exit 1; fi
# The leg's lever flags must reach the whole-program pass as well as the per-unit compiles: a rule that runs only under
# -tsan-whole-program (U1's, SingleThreaded.cpp) never saw them before 26 Sep 2026, and U1 measured nothing.
EXTRA_OPT=$(echo " ${TSAN_EXTRA_MLLVM:-} " | sed -E 's/ -mllvm / /g')
ARCHIVE=memcached-1.6.29.tar.gz
WORK=memcached-summaries-work
NPROC=${NPROC:-8}   # explicit: the host job rule (<= 80 % of threads summed over lanes) forbids $(nproc); audit A13 item 4

echo "compiler: $CLANG ($("$CLANG" --version | head -1))"
echo "tree: $TREE branch=$(git -C "$TREE" branch --show-current) head=$HEAD"
echo "ninja: $(ninja -n -C "$LLVM_TSAN_ROOT" 2>/dev/null | tail -1)"

rm -rf "$WORK"; mkdir -p "$WORK"
# Fetch when absent, then refuse to unpack an archive whose sha256 is not the pinned one
# (tools/source_archives.sha256): fetch_archive.sh verifies in both cases. Verifying alone assumed a plain build had
# fetched the archive first; a -wp build in a fresh tree runs this generator before any plain build and on
# 25 Sep 2026 died with "verify_archive: memcached-1.6.29.tar.gz does not exist" (U1 of U-CEIL).
"$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/../../tools/fetch_archive.sh" "$ARCHIVE" || exit 1
tar -xzf "$ARCHIVE" -C "$WORK" --strip-components=1
cd "$WORK"
CC="$CLANG" CFLAGS="-O2 -g" ./configure --prefix="$PWD" > configure.log 2>&1

# Same modules the real build links (memcached_SOURCES for this configure).
MODULES=$(make -n memcached 2>/dev/null | grep -o 'memcached-[a-z0-9_]*\.o' | LC_ALL=C sort -u | sed 's/^memcached-//; s/\.o$//')
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
# Explicit list (the -tsan-external-symbols rule, audit A13): the undefined symbols of every object linked into the
# program without IR. The 26 objects of the memcached target are exactly the 26 modules above, and libevent and the system
# libraries reach memcached only through callbacks it registers (address-taken), so the list is the header alone
# (checked 26 Sep 2026 against the build's object list).
echo "# tsan-external-symbols v1" > "$OUT/external-symbols.txt"
OPT_ARGS=(-tsan-use-analysis-summaries -tsan-whole-program -tsan-summary-dir="$OUT" -tsan-summary-id="$SUMMARY_ID" $EXTRA_OPT)
"$OPT" --help-hidden 2>/dev/null | grep -c -- '-tsan-external-symbols' > /dev/null && OPT_ARGS+=(-tsan-external-symbols="$OUT/external-symbols.txt")
# require<> by default: the analyses write their summary files themselves; print<> only adds a textual dump of the result
# (FFmpeg's EA dump ran for over 2 h on 26 Sep; require<> wrote a byte-identical ea_summary.txt in 35 s - a control run).
# GEN_PASS_MODE=print restores the dump.
MODE=${GEN_PASS_MODE:-require}; case "$MODE" in require|print) ;; *) echo "error: GEN_PASS_MODE must be require or print"; exit 1;; esac
for pass in single-threaded lock-ownership escape-analysis-global; do
  "$OPT" -disable-output -passes="$MODE<$pass>" "${OPT_ARGS[@]}" ../memcached.ll \
      > "$pass.$MODE.txt" 2>&1 || { echo "opt $MODE<$pass> failed, see $WORK/summarize/$pass.$MODE.txt"; exit 1; }
done
# evconf (1 Oct): the summary step runs only analyses, so evconf_summary.txt was never written; guarded by the flag.
case " ${TSAN_EXTRA_MLLVM:-} " in *tsan-evconf-spec*) "$OPT" -disable-output -passes=tsan-evconf-summary "${OPT_ARGS[@]}" ../memcached.ll > evconf.txt 2>&1 || { echo "opt tsan-evconf-summary failed"; exit 1; };; esac
ls -l "$OUT"
for f in st lo ea; do [ -s "$OUT/${f}_summary.txt" ] || echo "warning: $OUT/${f}_summary.txt missing or empty"; done
cd ../..
cp "$WORK"/summarize/*."$MODE".txt "$OUT"/
{
  echo "date: $(date -Iseconds)"
  echo "generator: $GEN_NAME sha256 $GEN_SHA"
  echo "compiler: $(readlink -f "$CLANG") ($("$CLANG" --version | head -1))"
  echo "tree: $TREE head=$HEAD $(git -C "$TREE" branch --show-current 2>/dev/null | sed 's/^/branch=/')"
  echo "ir_flags: $COMMON_FLAGS"
  echo "modules: $(echo $MODULES | tr '\n' ' ')"
  echo "opt: -passes=$MODE<single-threaded|lock-ownership|escape-analysis-global> ${OPT_ARGS[*]} (ST -> LO -> EA; the arguments actually passed)"
  echo "summary_id: $SUMMARY_ID"
  echo "sizes: $(wc -l "$OUT"/*_summary.txt | tr '\n' ';')"
} > "$OUT/PROVENANCE.txt"
cat "$OUT/PROVENANCE.txt"
echo "summaries written to $OUT/ — build with: USE_SUMMARIES=1 SUMMARIES_DIR=$OUT ./build_memcached.sh <config>"
