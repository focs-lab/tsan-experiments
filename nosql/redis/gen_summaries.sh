#!/bin/bash
# gen_summaries.sh — whole-program analysis summaries for redis-server, hardened-compiler edition.
#
# Replaces the summary block of the paper-era redis.sh (build_single_ll + three
# `opt -passes=print<...> -debug-only=...` runs) for the prototype compiler, where the summary
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
# Which generator produced a summary: its own sha256 goes into PROVENANCE (26 Sep 2026: generators changed between builds).
GEN_SHA=$(sha256sum < "${BASH_SOURCE[0]}" | cut -c1-16); GEN_NAME="$(basename "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/gen_summaries.sh"   # before any cd
cd "$(dirname "$0")"

# tools/tsan_compiler.sh picks the hardened prototype unless LLVM_TSAN_ROOT is set;
# $LLVM_ROOT_PATH / $LLVM_PATH from ~/.bashrc point at the unrelated llvm-capstone tree.
source ../../tools/tsan_compiler.sh
CLANG="$TSAN_CC"; OPT="$TSAN_OPT"; LLVM_LINK="$TSAN_LLVM_ROOT/bin/llvm-link"
for t in "$CLANG" "$OPT" "$LLVM_LINK"; do [ -x "$t" ] || { echo "missing $t"; exit 1; }; done
# Frozen per-hash copies (a frozen per-hash copy) are not git trees: take the id from TSAN_AUDIT_HASH.
if [ -f "$TSAN_LLVM_ROOT/TSAN_AUDIT_HASH" ]; then
  TREE="$TSAN_LLVM_ROOT"; HEAD=$(head -1 "$TSAN_LLVM_ROOT/TSAN_AUDIT_HASH" | grep -oE "[0-9a-f]{12}" | head -1)
else
  TREE=$(cd "$(dirname "$(readlink -f "$CLANG")")" && while [ ! -e .git ] && [ "$PWD" != / ]; do cd ..; done; pwd)
  HEAD=$(git -C "$TREE" rev-parse --short HEAD 2>/dev/null || "$CLANG" --version | grep -oE "[0-9a-f]{40}" | cut -c1-12)
fi
SUMMARY_ID="${SUMMARY_ID:-$HEAD}"
OUT="${1:-summaries-$HEAD}"
[[ "$OUT" = /* ]] || OUT="$PWD/$OUT"
# Never write into an existing, non-empty summary dir: the reader's id check ignores the flags and the list, so old files
# there would be reused silently (audit A13, H3).
if [ -d "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then echo "error: $OUT exists and is not empty; remove it or pass another dir"; exit 1; fi
# The leg's lever flags must reach the whole-program pass as well as the per-unit compiles: a rule that runs only under
# -tsan-whole-program (U1's, SingleThreaded.cpp) never saw them before 26 Sep 2026, and U1 measured nothing.
EXTRA_OPT=$(echo " ${TSAN_EXTRA_MLLVM:-} " | sed -E 's/ -mllvm / /g')
ARCHIVE="${ARCHIVE:-redis-7.0.15.tar.gz}"
[ -f "$ARCHIVE" ] || ARCHIVE="redis-polygon/$(basename "$ARCHIVE")"
[ -f "$ARCHIVE" ] || { echo "archive not found: $ARCHIVE"; exit 1; }
WORK=redis-summaries-work
NPROC=${NPROC:-8}   # explicit: the host job rule (<= 80 % of threads summed over lanes) forbids $(nproc); audit A13 item 4
NOINSTR_FLAGS="-w -mllvm -tsan-instrument-memory-accesses=0 -mllvm -tsan-instrument-func-entry-exit=0 \
  -mllvm -tsan-instrument-atomics=0 -mllvm -tsan-instrument-memintrinsics=0"

echo "compiler: $CLANG ($("$CLANG" --version | head -1))"
echo "tree: $TREE head=$HEAD"
echo "ninja: $(ninja -n -C "$TSAN_LLVM_ROOT" 2>/dev/null | tail -1)"

rm -rf "$WORK"; mkdir -p "$WORK"
# refuse to unpack an archive whose sha256 is not the pinned one (tools/source_archives.sha256)
VERIFY="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/../../tools/verify_archive.sh"
"$VERIFY" "$ARCHIVE" || exit 1
tar -xzf "$ARCHIVE" -C "$WORK" --strip-components=1
cd "$WORK/src"

# The compile lines the real build would run (same env as redis.sh: SANITIZER=thread,
# USE_JEMALLOC=no, CC=<hardened clang>).  `make -n` executes $(shell ...) hooks such as
# mkreleasehdr.sh, so release.h exists afterwards; deps are only needed for linking.
# A build that uses the CFG-TABLE proof (-tsan-phase-config-table-proof) records its compile flags in the debug info, so
# that the program digest the proof is bound to covers them (A57c L3b, 5 Oct); redis.sh adds the same flag to its build.
case " ${TSAN_EXTRA_MLLVM:-} " in *" -tsan-phase-config-table-proof "*) GRCL=-grecord-command-line;; *) GRCL="";; esac
CC="$CLANG" SANITIZER=thread USE_JEMALLOC=no REDIS_CFLAGS="$GRCL" make -n V=1 redis-server > make-n.txt 2>/dev/null || true
cat make-n.txt \
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
# Sound summaries interface: -tsan-whole-program on the linked IR (asserts nothing outside the module calls in
# except through taken addresses and main), files written to -tsan-summary-dir tagged with -tsan-summary-id.
# Explicit list (the -tsan-external-symbols rule, audit A13): deps/ are linked into redis-server but are not in
# the IR, and they call Redis BY NAME (hdr_histogram: #define hdr_malloc zmalloc, likewise zrealloc/zfree; A13 found
# zcalloc_num and zfree from libhdrhistogram.a; libhiredis.a and liblua.a are outside the IR too). Build deps/ exactly as
# `make redis-server` would (its .make-prerequisites step), take the deps objects from the real link line, and list
# their undefined symbols.
CC="$CLANG" SANITIZER=thread USE_JEMALLOC=no make -j"$NPROC" .make-prerequisites > deps-build.log 2>&1 \
  || { echo "deps build failed, see $WORK/src/deps-build.log"; exit 1; }
LINKLINE=$(grep -E ' -o redis-server( |$)' make-n.txt | tail -1)
[ -n "$LINKLINE" ] || { echo "no link line for redis-server in make-n.txt"; exit 1; }
NOIR=$(echo "$LINKLINE" | tr ' ' '\n' | grep -E '^\.\./deps/.*\.(a|o)$' | LC_ALL=C sort -u)
[ -n "$NOIR" ] || { echo "no deps objects on the link line"; exit 1; }
for o in $NOIR; do [ -f "$o" ] || { echo "deps object missing after the deps build: $o"; exit 1; }; done
LLVM_NM="$TSAN_LLVM_ROOT/bin/llvm-nm"; [ -x "$LLVM_NM" ] || LLVM_NM=llvm-nm-18
# Checked, not piped blind (audit A14 S2, 26 Sep): a failing llvm-nm used to leave a header-only list, i.e. "nothing outside the IR".
syms=""; if [ -n "$(echo $NOIR)" ]; then syms=$("$LLVM_NM" --undefined-only --format=just-symbols $NOIR) || { echo "error: llvm-nm failed on $NOIR"; exit 1; }; fi
{ echo "# tsan-external-symbols v1"; printf '%s\n' "$syms" | grep -v -E ':$|^$' | LC_ALL=C sort -u || true; } > external-symbols.txt   # C order: the list's bytes are digested into the summaries (f23eac85cb62), so they must not depend on the caller's locale
[ -z "$(echo $NOIR)" ] || [ "$(wc -l < external-symbols.txt)" -gt 1 ] || { echo "error: deps objects outside the IR ($NOIR) but an empty external list"; exit 1; }
echo "external list: $(( $(wc -l < external-symbols.txt) - 1 )) names from: $(echo $NOIR | tr '\n' ' ')"
rm -rf summarize; mkdir summarize; cd summarize
mkdir -p "$OUT"; cp ../external-symbols.txt "$OUT/external-symbols.txt"
OPT_ARGS=(-tsan-use-analysis-summaries -tsan-whole-program -tsan-summary-dir="$OUT" -tsan-summary-id="$SUMMARY_ID" $EXTRA_OPT)
"$OPT" --help-hidden 2>/dev/null | grep -c -- '-tsan-external-symbols' > /dev/null && OPT_ARGS+=(-tsan-external-symbols="$OUT/external-symbols.txt") \
  || echo "note: this compiler has no -tsan-external-symbols; the list is recorded but NOT applied (closed world assumed)"
# require<> by default: the analyses write their summary files themselves; print<> only adds a textual dump of the result
# (FFmpeg's EA dump ran for over 2 h on 26 Sep; require<> wrote a byte-identical ea_summary.txt in 35 s - a control run).
# GEN_PASS_MODE=print restores the dump.
MODE=${GEN_PASS_MODE:-require}; case "$MODE" in require|print) ;; *) echo "error: GEN_PASS_MODE must be require or print"; exit 1;; esac
for pass in single-threaded lock-ownership escape-analysis-global; do
  "$OPT" -disable-output -passes="$MODE<$pass>" "${OPT_ARGS[@]}" ../redis-server.ll \
      > "$pass.$MODE.txt" 2>&1 || { echo "opt $MODE<$pass> failed, see $WORK/src/summarize/$pass.$MODE.txt"; exit 1; }
done
# Phase guard (3 Oct): the closed-world admission record phase_summary.txt (the extern globals whose address
# every unit hands only to atomics, the pthread calls of one kind and plain loads/stores); the summary step runs only
# analyses, so it is written by its own pass, guarded by the flag. Without it no extern object is exempt (fail closed).
case " ${TSAN_EXTRA_MLLVM:-} " in *tsan-phase-guard-spec*) "$OPT" -disable-output -passes=tsan-phase-summary "${OPT_ARGS[@]}" ../redis-server.ll > phase.txt 2>&1 || { echo "opt tsan-phase-summary failed, see $WORK/src/summarize/phase.txt"; exit 1; }; [ -f "$OUT/phase_summary.txt" ] || { echo "error: tsan-phase-summary wrote no $OUT/phase_summary.txt"; exit 1; };; esac
# The linked program's digest (sources, headers, compile flags), which a build using the CFG-TABLE proof passes to
# config.c's compile so that the record is used only for this program (redis.sh reads it).
[ -n "$GRCL" ] && { "$OPT" -disable-output -passes=tsan-phase-summary -tsan-whole-program -tsan-phase-print-program-digest \
    ../redis-server.ll > "$OUT/program-digest.txt" && [ -s "$OUT/program-digest.txt" ] || { echo "could not print the program digest"; exit 1; }; }
ls -l "$OUT"
for f in st lo ea; do [ -s "$OUT/${f}_summary.txt" ] || echo "warning: $OUT/${f}_summary.txt missing or empty"; done
cd ../../..
cp "$WORK"/src/summarize/*."$MODE".txt "$OUT"/
cp "$WORK"/src/compile-lines.txt "$OUT"/
{
  echo "date: $(date -Iseconds)"
  echo "generator: $GEN_NAME sha256 $GEN_SHA"
  echo "compiler: $(readlink -f "$CLANG") ($("$CLANG" --version | head -1))"
  echo "tree: $TREE head=$HEAD $(git -C "$TREE" branch --show-current 2>/dev/null | sed 's/^/branch=/')"
  echo "summary_id: $SUMMARY_ID"
  echo "archive: $ARCHIVE ($(md5sum "$ARCHIVE" | cut -c1-8))"
  echo "ir_flags: real compile lines (compile-lines.txt) + $NOINSTR_FLAGS"
  echo "modules: $(echo $MODULES | tr '\n' ' ')"
  echo "opt: -passes=$MODE<single-threaded|lock-ownership|escape-analysis-global> ${OPT_ARGS[*]} (ST -> LO -> EA; the arguments actually passed)"
  echo "external list: $(( $(wc -l < "$OUT/external-symbols.txt") - 1 )) names (deps objects outside the IR: $(echo $NOIR | tr '\n' ' '))"
  echo "sizes: $(wc -l "$OUT"/*_summary.txt | tr '\n' ';')"
} > "$OUT/PROVENANCE.txt"
cat "$OUT/PROVENANCE.txt"
echo "summaries written to $OUT/ — build with: USE_SUMMARIES=1 SUMMARIES_DIR=$OUT BUILD_OPTIONS=\"sound\" ./redis.sh --compile-only"
