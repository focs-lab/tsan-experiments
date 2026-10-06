#!/bin/bash
# gen_summaries.sh — whole-program analysis summaries for the ffmpeg binary (sound interface), the counterpart of
# nosql/redis/gen_summaries.sh for an application whose compile lines come from configure + a non-recursive Makefile.
#
# "Whole program" = ffmpeg_g plus every FFmpeg library it links (libavcodec, libavformat, libavutil, libavfilter,
# libavdevice, libswscale, libswresample, libpostproc: the build uses --enable-shared, so these are .so files loaded by
# nothing but ffmpeg in the benchmark). x264/x265/gnutls are outside the module; they reach FFmpeg code only through
# function pointers FFmpeg hands them, which -tsan-whole-program already treats as escaping. Hand-written assembly
# (nasm) has no IR: those functions are external to the module, which is the conservative reading.
#
# How the IR is obtained: the REAL build runs once with a compiler wrapper (ir-cc) as --cc. For every compile it runs
# the compile unchanged except for the four NOINSTR flags (so the objects link and the build completes) and emits the
# same unit's IR with the same flags (-S -emit-llvm); for every link it records the output and its objects. Module
# membership is then read from the recorded link lines of ffmpeg_g and the libraries, not guessed from directories.
# Some objects are compiled into more than one library from the same source (e.g. log2_tab.c): later copies of an
# already-defined symbol are linked with --override, which is exact because the definitions are identical.
#
# Usage:  LLVM_TSAN_ROOT=<frozen copy> [SUMMARY_ID=<tag>] [NPROC=<jobs>] ./gen_summaries.sh [out_dir]
# Output: <out_dir>/{st,lo,ea}_summary.txt + PROVENANCE.txt + the print logs; default out_dir: summaries-<stamp>
# Then:   USE_SUMMARIES=1 SUMMARIES_DIR=<out_dir> BUILD_TAG=-wp ./build_ffmpeg.sh <config>
set -euo pipefail
# Which generator produced a summary: its own sha256 goes into PROVENANCE (26 Sep 2026: generators changed between builds).
GEN_SHA=$(sha256sum < "${BASH_SOURCE[0]}" | cut -c1-16); GEN_NAME="$(basename "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/gen_summaries.sh"   # before any cd
cd "$(dirname "$0")"
source ../../tools/tsan_compiler.sh
CLANG="$TSAN_CC"; OPT="$TSAN_OPT"; LLVM_LINK="$TSAN_LLVM_ROOT/bin/llvm-link"; LLVM_NM="$TSAN_LLVM_ROOT/bin/llvm-nm"
for t in "$CLANG" "$OPT" "$LLVM_LINK" "$LLVM_NM"; do [ -x "$t" ] || { echo "missing $t"; exit 1; }; done
if [ -f "$TSAN_LLVM_ROOT/TSAN_AUDIT_HASH" ]; then
  HEAD=$(head -1 "$TSAN_LLVM_ROOT/TSAN_AUDIT_HASH" | grep -oE "[0-9a-f]{12}" | head -1)
else
  HEAD=$("$CLANG" --version | grep -oE "[0-9a-f]{40}" | cut -c1-12)
fi
SUMMARY_ID="${SUMMARY_ID:-$HEAD}"
OUT="${1:-summaries-$HEAD}"; [[ "$OUT" = /* ]] || OUT="$PWD/$OUT"
# Never write into an existing, non-empty summary dir (audit A13, H3); the leg's lever flags reach the opt runs too.
if [ -d "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then echo "error: $OUT exists and is not empty; remove it or pass another dir"; exit 1; fi
EXTRA_OPT=$(echo " ${TSAN_EXTRA_MLLVM:-} " | sed -E 's/ -mllvm / /g')
ARCHIVE=FFmpeg-n4.3.9.tar.gz
NPROC=${NPROC:-8}
NOINSTR="-w -mllvm -tsan-instrument-memory-accesses=0 -mllvm -tsan-instrument-func-entry-exit=0 -mllvm -tsan-instrument-atomics=0 -mllvm -tsan-instrument-memintrinsics=0"
# The build's own base flags (build_ffmpeg.sh), without any analysis flag: the analyses see the IR the binary is built from.
CFLAGS_BASE="-fsanitize=thread ${TSAN_EXTRA_MLLVM:-} -g -O2"
WORK=$PWD/ffmpeg-summaries-work
echo "compiler: $CLANG ($("$CLANG" --version | head -1)); summary id $SUMMARY_ID; jobs $NPROC"

../../tools/fetch_archive.sh "$ARCHIVE"
ARCHIVE_MD5=$(md5sum "$ARCHIVE" | cut -c1-8)
rm -rf "$WORK"; mkdir -p "$WORK/src"
tar -xzf "$ARCHIVE" -C "$WORK/src" --strip-components=1

# ir-cc: compile unchanged but uninstrumented, plus the unit's IR; record link lines.
cat > "$WORK/ir-cc" <<EOF
#!/bin/bash
REAL="$CLANG"; NOINSTR="$NOINSTR"; LINKS="$WORK/links.txt"
EOF
cat >> "$WORK/ir-cc" <<'EOF'
args=("$@"); out=""; compile=0; src=""
for ((i=0;i<${#args[@]};i++)); do
  case "${args[$i]}" in -c) compile=1;; -o) out="${args[$((i+1))]}";; -E|-S|-M|-MM) exec "$REAL" "$@";; *.c) src="${args[$i]}";; esac
done
if [ $compile = 1 ] && [ -n "$src" ] && [[ "$out" == *.o ]] && [[ "$out" != /tmp/* ]]; then
  "$REAL" "$@" $NOINSTR || exit $?
  ir=(); skip=0
  for ((i=0;i<${#args[@]};i++)); do
    a="${args[$i]}"
    if [ $skip = 1 ]; then skip=0; continue; fi
    case "$a" in -c|-MMD|-MD|-MP) continue;; -MF|-MT|-MQ) skip=1; continue;; -o) ir+=(-o "${out%.o}.ll"); skip=1; continue;; esac
    ir+=("$a")
  done
  exec "$REAL" "${ir[@]}" $NOINSTR -S -emit-llvm
fi
if [ $compile = 0 ] && [ -n "$out" ] && [[ "$out" != /tmp/* ]]; then
  objs=(); for a in "$@"; do case "$a" in *.o) objs+=("$(realpath -m "$a")");; -l*) objs+=("$a");; esac; done
  echo "$(realpath -m "$out")	${objs[*]}" >> "$LINKS"
fi
exec "$REAL" "$@"
EOF
chmod +x "$WORK/ir-cc"

cd "$WORK/src"
# The configure line of build_ffmpeg.sh, with ir-cc as the compiler and without an install step.
./configure --prefix="$WORK/install" --extra-libs="-lpthread -lm" --cc="$WORK/ir-cc" --cxx="$TSAN_CXX" \
  --extra-cflags="$CFLAGS_BASE" --extra-cxxflags="$CFLAGS_BASE" --extra-ldflags="$CFLAGS_BASE" \
  --disable-doc --enable-gpl --enable-gnutls --enable-libx264 --enable-libx265 --enable-debug=3 --enable-shared \
  --disable-optimizations --disable-stripping > "$WORK/configure.log" 2>&1 || { echo "configure failed, see $WORK/configure.log"; exit 1; }
make -j"$NPROC" > "$WORK/make.log" 2>&1 || { echo "make failed, see $WORK/make.log"; exit 1; }

# Module membership from the recorded link lines: ffmpeg_g's objects plus those of every library it links.
LINKS="$WORK/links.txt"
mainline=$(awk -F'\t' '$1 ~ /\/ffmpeg_g$/' "$LINKS" | tail -1)
[ -n "$mainline" ] || { echo "no link line for ffmpeg_g in $LINKS"; exit 1; }
objs=$(echo "$mainline" | cut -f2 | tr ' ' '\n' | grep '\.o$' || true)
for lib in $(echo "$mainline" | cut -f2 | tr ' ' '\n' | sed -n 's/^-l//p'); do
  line=$(awk -F'\t' -v l="lib$lib" '$1 ~ ("/" l "\\.so") ' "$LINKS" | tail -1)
  [ -n "$line" ] || continue                              # a system library (x264, x265, gnutls, m, pthread, ...)
  echo "library lib$lib: $(echo "$line" | cut -f2 | tr ' ' '\n' | grep -c '\.o$') objects"
  objs="$objs"$'\n'"$(echo "$line" | cut -f2 | tr ' ' '\n' | grep '\.o$')"
done
objs=$(echo "$objs" | grep . | LC_ALL=C sort -u)   # C order: link order decides which duplicate definition is primary (26 Sep)
nobj=$(echo "$objs" | wc -l); lls=(); noir=()
for o in $objs; do if [ -s "${o%.o}.ll" ]; then lls+=("${o%.o}.ll"); else noir+=("$o"); fi; done
echo "modules: ${#lls[@]} with IR of $nobj objects; ${#noir[@]} without IR (assembly):"
printf '  %s\n' "${noir[@]}" | sed "s#$WORK/src/##" | head -50
if grep -l "call.*@__tsan_\(read\|write\|func_entry\)" "${lls[@]}" >/dev/null 2>&1; then echo "error: instrumentation calls present in emitted IR"; exit 1; fi

# Duplicate definitions (the same source compiled into several libraries, e.g. ff_reverse from reverse.c in libavutil and
# libavcodec): first definition is primary, later
# modules that redefine an already-defined external symbol are linked with --override.
declare -A seen; primary=(); override=()
for f in "${lls[@]}"; do
  dup=0
  while read -r s; do [ -n "$s" ] || continue; if [ -n "${seen[$s]:-}" ]; then dup=1; else seen[$s]=1; fi
  done < <("$LLVM_NM" --defined-only --extern-only --format=just-symbols "${f%.ll}.o" 2>/dev/null)   # the unit's real object: llvm-nm reads no textual IR
  if [ $dup = 1 ]; then override+=(--override "$f"); else primary+=("$f"); fi
done
echo "linking ${#primary[@]} modules (+ $(( ${#override[@]} / 2 )) with duplicate definitions via --override)"
"$LLVM_LINK" -o "$WORK/ffmpeg-whole.bc" "${primary[@]}" "${override[@]}"

rm -rf "$WORK/summarize"; mkdir "$WORK/summarize"; cd "$WORK/summarize"; mkdir -p "$OUT"
# Explicit list (the -tsan-external-symbols rule, audit A13): the undefined symbols of the objects linked without IR,
# i.e. the nasm objects. A13: they import only data (119 names, no functions); the data names stay in, since SWMR and LO
# read globals.
# Checked, not piped blind (audit A14 S2, 26 Sep): a failing llvm-nm used to leave a header-only list, i.e. "nothing outside the IR".
syms=""; if [ ${#noir[@]} -gt 0 ]; then syms=$("$LLVM_NM" --undefined-only --format=just-symbols "${noir[@]}") || { echo "error: llvm-nm failed on the objects without IR"; exit 1; }; fi
{ echo "# tsan-external-symbols v1"; printf '%s\n' "$syms" | grep -v -E ':$|^$' | LC_ALL=C sort -u || true; } > "$OUT/external-symbols.txt"   # C order: the list's bytes are digested into the summaries (f23eac85cb62), so they must not depend on the caller's locale
[ ${#noir[@]} -eq 0 ] || [ "$(wc -l < "$OUT/external-symbols.txt")" -gt 1 ] || { echo "error: ${#noir[@]} objects without IR but an empty external list"; exit 1; }
echo "external list: $(( $(wc -l < "$OUT/external-symbols.txt") - 1 )) names from ${#noir[@]} objects without IR"
OPT_ARGS=(-tsan-use-analysis-summaries -tsan-whole-program -tsan-summary-dir="$OUT" -tsan-summary-id="$SUMMARY_ID" $EXTRA_OPT)
"$OPT" --help-hidden 2>/dev/null | grep -c -- '-tsan-external-symbols' > /dev/null && OPT_ARGS+=(-tsan-external-symbols="$OUT/external-symbols.txt") \
  || echo "note: this compiler has no -tsan-external-symbols; the list is recorded but NOT applied (closed world assumed)"
# require<> by default: the analyses write their summary files themselves; print<> only adds a textual dump of the result,
# which for EA over the 1927-module program ran for over 2 h (26 Sep 03:57) while the analysis itself takes ~2 min.
# GEN_PASS_MODE=print restores the dump. A control run (26 Sep): require<escape-analysis-global> on the same linked module wrote an
# ea_summary.txt byte-identical to the print<> run's, in 35 s.
MODE=${GEN_PASS_MODE:-require}; case "$MODE" in require|print) ;; *) echo "error: GEN_PASS_MODE must be require or print"; exit 1;; esac
for pass in single-threaded lock-ownership escape-analysis-global; do
  /usr/bin/time -f "$pass: %e s, %M KB" "$OPT" -disable-output -passes="$MODE<$pass>" "${OPT_ARGS[@]}" \
      "$WORK/ffmpeg-whole.bc" > "$pass.$MODE.txt" 2>&1 \
    || { echo "opt $MODE<$pass> failed, see $WORK/summarize/$pass.$MODE.txt"; exit 1; }
  tail -1 "$pass.$MODE.txt"
done
for f in st lo ea; do [ -s "$OUT/${f}_summary.txt" ] || echo "warning: $OUT/${f}_summary.txt missing or empty"; done
cp "$WORK"/summarize/*."$MODE".txt "$WORK/links.txt" "$OUT"/
{
  echo "date: $(date -Iseconds)"
  echo "generator: $GEN_NAME sha256 $GEN_SHA"
  echo "compiler: $(readlink -f "$CLANG") ($("$CLANG" --version | head -1))"
  echo "summary_id: $SUMMARY_ID"
  echo "archive: $ARCHIVE ($ARCHIVE_MD5)"
  echo "ir_flags: build_ffmpeg.sh's configure line and base flags ($CFLAGS_BASE) + $NOINSTR, captured by ir-cc during a real build"
  echo "whole program: ffmpeg_g + $(echo "$mainline" | cut -f2 | tr ' ' '\n' | sed -n 's/^-l//p' | tr '\n' ' ')(FFmpeg libraries among them are in the module)"
  echo "modules: ${#lls[@]} with IR, ${#noir[@]} assembly objects without IR, $(( ${#override[@]} / 2 )) linked with --override"
  echo "opt: -passes=$MODE<single-threaded|lock-ownership|escape-analysis-global> ${OPT_ARGS[*]} (ST -> LO -> EA; the arguments actually passed)"
  echo "external list: $(( $(wc -l < "$OUT/external-symbols.txt") - 1 )) names from ${#noir[@]} objects without IR"
  echo "sizes: $(wc -l "$OUT"/*_summary.txt | tr '\n' ';')"
} > "$OUT/PROVENANCE.txt"
cat "$OUT/PROVENANCE.txt"
