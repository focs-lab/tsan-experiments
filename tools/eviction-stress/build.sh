#!/bin/bash
# Build evict_stress with the hardened prototype in stock / sound / allopt flavours.
# LLVM_TSAN_ROOT overrides the compiler (e.g. the paper-state build on /extra).
set -euo pipefail
cd "$(dirname "$0")"
source ../tsan_compiler.sh
OUT="${1:-bin}"
mkdir -p "$OUT"
declare -A CFG=(
  [tsan]=""
  [tsan-sound]="-mllvm -tsan-use-escape-analysis-global -mllvm -tsan-use-lock-ownership -mllvm -tsan-use-single-threaded -mllvm -tsan-use-swmr"
  [tsan-dom_peeling-ea-lo-st-swmr]="-mllvm -tsan-use-dominance-analysis -mllvm -tsan-use-loop-peeling=true -mllvm -tsan-use-escape-analysis-global -mllvm -tsan-use-lock-ownership -mllvm -tsan-use-single-threaded -mllvm -tsan-use-swmr"
  [tsan-ea]="-mllvm -tsan-use-escape-analysis-global"
  [tsan-st]="-mllvm -tsan-use-single-threaded"
)
echo "compiler: $TSAN_CC ($("$TSAN_CC" --version | head -1))" | tee "$OUT/build_info.txt"
for c in "${!CFG[@]}"; do
  flags="-O2 -g -fsanitize=thread -fno-omit-frame-pointer ${CFG[$c]}"
  "$TSAN_CC" $flags -S -emit-llvm -o "$OUT/evict_stress.$c.ll" evict_stress.c
  "$TSAN_CC" $flags -o "$OUT/evict_stress.$c" evict_stress.c
  # instrumentation left in the burst functions and in the granule stores
  nl=$(awk '/^define.*@burst_local/,/^}/' "$OUT/evict_stress.$c.ll" | grep -c "@__tsan_\(read\|write\)" || true)
  ns=$(awk '/^define.*@burst_shared/,/^}/' "$OUT/evict_stress.$c.ll" | grep -c "@__tsan_\(read\|write\)" || true)
  ng=$(grep -c "@__tsan_write1(ptr .*@g" "$OUT/evict_stress.$c.ll" || true)
  printf "%-34s flags: %s\n%-34s tsan calls: burst_local=%s burst_shared=%s stores-to-g=%s\n" "$c" "${CFG[$c]:-<none>}" "" "$nl" "$ns" "$ng" | tee -a "$OUT/build_info.txt"
done
