#!/bin/bash
# P4 driver: deterministic sweep + randomised burst lengths for every build in bin/.
#   ./run.sh [bin_dir] [runs]          (default bin, 1000)
# Output: results/<date>-<compiler-hash>/{report.md,sweep.txt,random.<cfg>.<mode>.txt}
set -euo pipefail
cd "$(dirname "$0")"
BIN="${1:-bin}"; R="${2:-1000}"; SEED="${SEED:-20260902}"; NMAX="${NMAX:-1023}"; JOBS="${JOBS:-32}"
HASH=$(head -1 "$BIN/build_info.txt" | grep -oE '\b[0-9a-f]{40}\b' | head -1 | cut -c1-12 || true)
OUT="results/$(date +%F)-${HASH:-unknown}"; mkdir -p "$OUT"
CFGS=$(ls "$BIN" | grep -E '^evict_stress\.[^.]+$' | sed 's/^evict_stress\.//' | sort)
export TSAN_OPTIONS="exitcode=0 report_bugs=1"

# (no pipeline: with pipefail a `grep -q` that exits early turns every run into a miss)
detected() { local out; out=$("$BIN/evict_stress.$1" $2 $3 ${4:-} 2>&1 || true); case "$out" in *"WARNING: ThreadSanitizer: data race"*) echo 1;; *) echo 0;; esac; }
export -f detected; export BIN

{
  echo "# P4 eviction stress -- $(date -Iseconds)"
  echo; sed 's/^/    /' "$BIN/build_info.txt"; echo
  echo "Runtime: $($BIN/evict_stress.tsan 0 2>&1 | grep -o 'ThreadSanitizer.*' | head -1 || true) TSAN_OPTIONS=\"$TSAN_OPTIONS\""
  echo
  echo "## Deterministic sweep: burst length 0..15, 3 runs per value"
  echo
  echo "Each character is one burst length (0..15): 1 = race reported in all 3 runs, 0 = in none, ? = mixed."
  echo
  echo '| config | local (N writes to a private heap buffer) | shared (M writes to an escaping buffer) |'
  echo '|---|---|---|'
} > "$OUT/report.md"
: > "$OUT/sweep.txt"
for c in $CFGS; do
  row="| $c |"
  for mode in local shared; do
    pat=""
    for n in $(seq 0 15); do
      d=0; for r in 1 2 3; do d=$((d + $(detected $c $n $mode))); done
      echo "$c $mode n=$n detected $d/3" >> "$OUT/sweep.txt"
      case $d in 3) pat+="1";; 0) pat+="0";; *) pat+="?";; esac
    done
    row+=" \`$pat\` |"
  done
  echo "$row" >> "$OUT/report.md"
done

# Random burst lengths: the same fixed-seed sequence of (N, M) pairs for every build.
python3 - "$SEED" "$R" "$NMAX" > "$OUT/random-args.txt" <<'PY'
import random, sys
seed, R, nmax = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
rng = random.Random(seed)
for i in range(R): print(rng.randint(0, nmax), rng.randint(0, nmax))
PY
{
  echo
  echo "## Randomised burst lengths: $R runs per cell, N and M uniform in [0, $NMAX] (seed $SEED, same sequence for every build)"
  echo
  echo "Detection rate of the planted race (95% Wilson interval).  A traced burst makes F4's trace position"
  echo "depend on the burst length, so the victim cell is uniform over the 4 cells and A's record survives"
  echo "with probability 3/4; an elided burst makes the position a per-binary constant and the outcome fixed."
  echo
  echo '| config | local: N private writes | shared: M escaping writes | mixed: N private + M escaping |'
  echo '|---|---|---|---|'
} >> "$OUT/report.md"
wilson() { python3 -c "
import math,sys; k,n=int(sys.argv[1]),int(sys.argv[2]); p=k/n; z=1.96
den=1+z*z/n; c=(p+z*z/(2*n))/den; h=z*math.sqrt(p*(1-p)/n+z*z/(4*n*n))/den
print(f'{100*p:.1f}% [{100*(c-h):.1f}, {100*(c+h):.1f}]')" "$1" "$2"; }
for c in $CFGS; do
  row="| $c |"
  for mode in local shared mixed; do
    f="$OUT/random.$c.$mode.txt"
    awk -v c=$c -v m=$mode '{ if (m=="local") print c, $1, m; else if (m=="shared") print c, $2, m; else print c, $1, m, $2 }' "$OUT/random-args.txt" \
      | xargs -P "$JOBS" -L 1 bash -c 'echo "$@ $(detected "$@")"' _ > "$f"
    k=$(awk '{s+=$NF} END{print s+0}' "$f"); n=$(wc -l < "$f")
    row+=" $k/$n = $(wilson $k $n) |"
  done
  echo "$row" >> "$OUT/report.md"
done
# Random private burst behind a fixed escaping prefix: the elided build's constant outcome
# is whatever the prefix makes it -- 0% for some prefixes, 100% for others -- while a build
# that traces the burst stays at ~3/4 whatever the prefix.
RF=$((R / 5))
{
  echo
  echo "## Fixed escaping prefix M, random private burst N ($RF runs per cell, first $RF pairs of the sequence)"
  echo
  echo '| config | M=0 | M=1 | M=2 | M=3 |'
  echo '|---|---|---|---|---|'
} >> "$OUT/report.md"
for c in $CFGS; do
  row="| $c |"
  for m in 0 1 2 3; do
    f="$OUT/prefix.$c.m$m.txt"
    head -n "$RF" "$OUT/random-args.txt" | awk -v c=$c -v m=$m '{ print c, $1, "mixed", m }' \
      | xargs -P "$JOBS" -L 1 bash -c 'echo "$@ $(detected "$@")"' _ > "$f"
    k=$(awk '{s+=$NF} END{print s+0}' "$f"); n=$(wc -l < "$f")
    row+=" $k/$n |"
  done
  echo "$row" >> "$OUT/report.md"
done
echo >> "$OUT/report.md"
echo "Per-run outcomes: random.<config>.<mode>.txt, prefix.<config>.m<M>.txt (columns: config, N[, mode[, M]], detected)." >> "$OUT/report.md"
cat "$OUT/report.md"
