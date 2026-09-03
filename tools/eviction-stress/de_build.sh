#!/bin/bash
# Build de_stress with the final audit compiler: stock, sound, DE-only, AllOpt+peel (all with the shadow probe).
set -euo pipefail; cd "$(dirname "$0")"
export LLVM_TSAN_ROOT=${LLVM_TSAN_ROOT:-/extra/alexey/builds/tsan-audit-f80e80b1dbe6}
source ../tsan_compiler.sh
OUT="${1:-bin-de}"; mkdir -p "$OUT"
declare -A CFG=(
  [tsan]=""
  [tsan-sound]="-mllvm -tsan-use-escape-analysis-global -mllvm -tsan-use-lock-ownership -mllvm -tsan-use-single-threaded -mllvm -tsan-use-swmr"
  [tsan-dom]="-mllvm -tsan-use-dominance-analysis"
  [tsan-dom_peeling-ea-lo-st-swmr]="-mllvm -tsan-use-dominance-analysis -mllvm -tsan-use-loop-peeling=true -mllvm -tsan-use-escape-analysis-global -mllvm -tsan-use-lock-ownership -mllvm -tsan-use-single-threaded -mllvm -tsan-use-swmr"
)
echo "compiler: $TSAN_CC ($("$TSAN_CC" --version | head -1))" | tee "$OUT/build_info.txt"
for c in tsan tsan-sound tsan-dom tsan-dom_peeling-ea-lo-st-swmr; do
  flags="-O2 -g -fsanitize=thread -fno-omit-frame-pointer -DSHADOW_PROBE ${CFG[$c]}"
  "$TSAN_CC" $flags -S -emit-llvm -o "$OUT/de_stress.$c.ll" de_stress.c
  "$TSAN_CC" $flags -o "$OUT/de_stress.$c" de_stress.c
  na=$(awk '/^define.*@a_body/,/^}/' "$OUT/de_stress.$c.ll" | grep -c "@__tsan_write1" || true)
  nb=$(awk '/^define.*@burst_shared/,/^}/' "$OUT/de_stress.$c.ll" | grep -c "@__tsan_\(read\|write\)" || true)
  printf "%-34s flags: %s\n%-34s tsan calls: a_body stores=%s burst_shared=%s\n" "$c" "${CFG[$c]:-<none>}" "" "$na" "$nb" | tee -a "$OUT/build_info.txt"
done
