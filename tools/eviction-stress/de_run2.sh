#!/bin/bash
# Symmetric DE eviction stress driver: sweep M=0..15 and 1000 fixed-seed random M per build.
set -uo pipefail; cd "$(dirname "$0")"
BIN="${1:-bin-de2}"; R="${2:-1000}"; SEED="${SEED:-20260903}"; JOBS="${JOBS:-16}"
HASH=$(head -1 "$BIN/build_info.txt" | grep -oE '\b[0-9a-f]{40}\b' | head -1 | cut -c1-12 || true)
OUT="results/de2-$(date +%F)-${HASH:-unknown}"; mkdir -p "$OUT"
CFGS="tsan tsan-sound tsan-dom tsan-dom_peeling-ea-lo-st-swmr"
export TSAN_OPTIONS="exitcode=0 report_bugs=1"
# one run -> "cfg M a_f4 c_f4 a_a2 c_a2 a_by c_by AB CB"
one() { local out st ab cb; out=$("$BIN/de_stress2.$1" $2 ${3:-0} ${4:-0} 2>&1 || true)
  st=$(printf "%s" "$out" | grep -o "a_after_f4=[01] c_after_f4=[01] a_after_a2=[01] c_after_a2=[01] a_after_by=[01] c_after_by=[01]" | grep -oE "[01]" | tr '\n' ' ')
  # classify by the previous access's function: A-B = a_body, C-B = thread_c (B's burst buffer is its own)
  ab=$(printf "%s" "$out" | grep -A6 "Previous write of size 1" | grep -c "#0 a_body ")
  cb=$(printf "%s" "$out" | grep -A6 "Previous write of size 1" | grep -c "#0 thread_c ")
  echo "$1 $2 ${3:-0} ${4:-0} ${st:-? ? ? ? ? ?} $((ab>0)) $((cb>0))"; }
export -f one; export BIN
{ echo "# Symmetric DE eviction stress -- $(date -Iseconds)"; echo; sed 's/^/    /' "$BIN/build_info.txt"; echo
  echo "Cells: A/C present after F4's store . after A's second store . after B's y store | races A-B C-B"; echo
  echo "## Sweep M = 0..15 (A's burst 0, B's burst 0)"; echo; echo "| config | M=0 .. 15 |"; echo "|---|---|"
  for c in $CFGS; do printf "| %s |" "$c"; for m in $(seq 0 15); do read -r _ _ _ _ af cf aa ca ab cb AB CB <<< "$(one $c $m 0 0)"; printf " %s%s.%s%s.%s%s\\|%s%s" $af $cf $aa $ca $ab $cb $AB $CB; done; echo " |"; done; echo
  echo "## Sweep of A's burst MA = 0..15 at M = 2 (A's record evicted by F4), B's burst 1"; echo; echo "| config | MA=0 .. 15 |"; echo "|---|---|"
  for c in $CFGS; do printf "| %s |" "$c"; for ma in $(seq 0 15); do read -r _ _ _ _ af cf aa ca ab cb AB CB <<< "$(one $c 2 $ma 1)"; printf " %s%s.%s%s.%s%s\\|%s%s" $af $cf $aa $ca $ab $cb $AB $CB; done; echo " |"; done; echo
} > "$OUT/report.md"
python3 -c "import random; rnd=random.Random($SEED); print('\n'.join('%d %d %d' % (rnd.randint(0,1023), rnd.randint(0,1023), rnd.randint(0,1023)) for _ in range($R)))" > "$OUT/random-m.txt"
for c in $CFGS; do sed "s/^/$c /" "$OUT/random-m.txt" | xargs -P "$JOBS" -L 1 bash -c 'one "$@"' _ > "$OUT/random.$c.txt"; done
python3 - "$OUT" $CFGS >> "$OUT/report.md" <<'PY'
import sys, math
out=sys.argv[1]; cfgs=sys.argv[2:]
def w(k,n):
    if n==0: return "n/a"
    z=1.96; p=k/n; d=1+z*z/n; c=p+z*z/(2*n); h=z*math.sqrt(p*(1-p)/n+z*z/(4*n*n))
    return f"{k}/{n} = {100*k/n:.1f} % [{100*(c-h)/d:.1f}, {100*(c+h)/d:.1f}]"
def f(k,n): return f"{k}/{n} = {100*k/n:.1f} %" if n else "n/a"
print("## Random (M, MA, MB) in [0, 1023]^3, 1000 runs per build (same sequence for all builds)\n")
print("| config | races/run (mean) | A–B reported | C–B reported | (i) A's record evicted by F4 | A–B given (i) | C–B given (i) | (ii) C's record evicted by A's 2nd store | C–B given (ii) | C evicted by F4 | C–B given that |")
print("|---|---|---|---|---|---|---|---|---|---|---|")
for c in cfgs:
    rows=[l.split() for l in open(f"{out}/random.{c}.txt")]; n=len(rows)
    AB=[int(r[10]) for r in rows]; CB=[int(r[11]) for r in rows]
    i_=[r for r in rows if r[4]=="0"]; ii=[r for r in rows if r[5]=="1" and r[7]=="0"]; cf4=[r for r in rows if r[5]=="0"]
    print(f"| {c} | {sum(AB)+sum(CB)}/{n} = {(sum(AB)+sum(CB))/n:.2f} | {w(sum(AB),n)} | {w(sum(CB),n)} | {len(i_)}/{n} | {f(sum(int(r[10]) for r in i_),len(i_))} | {f(sum(int(r[11]) for r in i_),len(i_))} | {len(ii)}/{n} | {f(sum(int(r[11]) for r in ii),len(ii))} | {len(cf4)}/{n} | {f(sum(int(r[11]) for r in cf4),len(cf4))} |")
PY
tail -8 "$OUT/report.md"
