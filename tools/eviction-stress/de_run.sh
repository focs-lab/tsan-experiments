#!/bin/bash
# DE eviction stress driver: sweep M=0..15 and 1000 fixed-seed random M per build; rates conditioned on
# whether A's first record was evicted between its two stores (from the shadow probe).
set -uo pipefail; cd "$(dirname "$0")"
BIN="${1:-bin-de}"; R="${2:-1000}"; SEED="${SEED:-20260903}"; JOBS="${JOBS:-16}"
HASH=$(head -1 "$BIN/build_info.txt" | grep -oE '\b[0-9a-f]{40}\b' | head -1 | cut -c1-12 || true)
OUT="results/de-$(date +%F)-${HASH:-unknown}"; mkdir -p "$OUT"
CFGS="tsan tsan-sound tsan-dom tsan-dom_peeling-ea-lo-st-swmr"
export TSAN_OPTIONS="exitcode=0 report_bugs=1"
one() { local out; out=$("$BIN/de_stress.$1" $2 2>&1 || true); local ev r=0; ev=$(printf "%s" "$out" | grep -o "a_evicted=[01]" | cut -d= -f2); case "$out" in *"WARNING: ThreadSanitizer: data race"*) r=1;; esac; echo "$1 $2 ${ev:-?} $r"; }
export -f one; export BIN
{ echo "# DE eviction stress -- $(date -Iseconds)"; echo; sed 's/^/    /' "$BIN/build_info.txt"; echo
  echo "Columns: config, M (escaping burst length of the evicting thread), a_evicted (A's first record gone after the evicting store), race (reported)."; echo
  echo "## Sweep M = 0..15 (a_evicted / race per M)"; echo
  for c in $CFGS; do printf "| %s |" "$c"; for m in $(seq 0 15); do read -r _ _ ev r <<< "$(one $c $m)"; printf " %s/%s" "$ev" "$r"; done; echo " |"; done | sed '1i | config | M=0 .. 15: a_evicted/race |\n|---|---|'
  echo
} > "$OUT/report.md"
python3 -c "import random; rnd=random.Random($SEED); print('\n'.join(str(rnd.randint(0,1023)) for _ in range($R)))" > "$OUT/random-m.txt"
for c in $CFGS; do sed "s/^/$c /" "$OUT/random-m.txt" | xargs -P "$JOBS" -L 1 bash -c 'one "$@"' _ > "$OUT/random.$c.txt"; done
python3 - "$OUT" $CFGS >> "$OUT/report.md" <<'PY'
import sys, math, collections
out = sys.argv[1]; cfgs = sys.argv[2:]
def wilson(k, n):
    if n == 0: return (0, 0)
    z = 1.96; p = k / n; d = 1 + z*z/n; c = p + z*z/(2*n); h = z*math.sqrt(p*(1-p)/n + z*z/(4*n*n))
    return ((c-h)/d, (c+h)/d)
print("## Random M in [0, 1023], %s runs per build (seed shared by all builds)\n" % "1000")
print("| config | detected (all runs) | A's record evicted between the stores | detected \\| evicted | detected \\| not evicted |")
print("|---|---|---|---|---|")
for c in cfgs:
    rows = [l.split() for l in open(f"{out}/random.{c}.txt")]
    n = len(rows); det = sum(int(r[3]) for r in rows)
    ev = [r for r in rows if r[2] == "1"]; ne = [r for r in rows if r[2] == "0"]
    dev = sum(int(r[3]) for r in ev); dne = sum(int(r[3]) for r in ne)
    lo, hi = wilson(det, n)
    f = lambda k, m: f"{k}/{m} = {100*k/m:.1f} %" if m else "n/a"
    print(f"| {c} | {det}/{n} = {100*det/n:.1f} % [{100*lo:.1f}, {100*hi:.1f}] | {len(ev)}/{n} | {f(dev, len(ev))} | {f(dne, len(ne))} |")
PY
echo; cat "$OUT/report.md" | tail -12
