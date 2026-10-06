#!/bin/bash
# test_fail_fast.sh -- a cell that FAILED is not a cell the machine spoilt, and a leg says so and stops.
#
# Covers the defect of 22 Sep 2026: meta_tool.py folded `rc != 0` into `disturbed`, so a MySQL leg whose
# workload directory was missing filed 30 cells as machine disturbance, re-ran each one, and reported NO
# DATA -- the cause visible in the first cell and hidden by every cell after it. The tests below pin the
# two halves of the fix and, as importantly, the HEALTHY path: a real shipped Redis cell must mark exactly
# as it marked before, or the fix has bought a true negative with a false one.
#
# Runs no workload and touches no benchmark processor; every case is metadata plus one stubbed leg.
set -uo pipefail
cd "$(dirname "$0")"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n     %s\n' "$1" "$2"; fails=$((fails + 1)); }
meta() { printf '%s\n' "$2" > "$T/$1.json"; echo "$T/$1.json"; }

echo "1. a cell that failed is FAILED, not DISTURBED, and is never re-run"
m=$(meta failed '{"app":"redis","config":"c","run":1,"rc":1,"seconds":0.4,"outside_busy_share":0.0,"error":"cd: no such file"}')
out=$(python3 ./meta_tool.py mark "$m" 0.10)
case "$out" in "FAILED rc=1") ok "mark says $out";; *) bad "mark should say FAILED rc=1" "said: $out";; esac
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); sys.exit(0 if (m["failed"] and not m["disturbed"]) else 1)' "$m" \
  && ok "failed=true, disturbed=false" || bad "the two states must not be the same field" "$(cat "$m")"
python3 ./meta_tool.py is-disturbed "$m"; case $? in 1) ok "is-disturbed says no, so the end-of-leg loop never re-runs it";; *) bad "a failed cell must not be re-run as disturbed" "is-disturbed exited 0";; esac
python3 ./meta_tool.py is-done "$m"; case $? in 1) ok "is-done says no, so a resumed leg redoes it";; *) bad "a failed cell must not count as done" "is-done exited 0";; esac

echo "2. a disturbed cell is still disturbed (the gate the fix must not disable)"
m=$(meta disturbed '{"app":"redis","config":"c","run":1,"rc":0,"seconds":30,"outside_busy_share":0.5}')
out=$(python3 ./meta_tool.py mark "$m" 0.10)
case "$out" in DISTURBED) ok "mark says DISTURBED";; *) bad "a clean run above the threshold is still disturbed" "said: $out";; esac
python3 ./meta_tool.py is-disturbed "$m"; case $? in 0) ok "is-disturbed says yes, so it is re-run once as before";; *) bad "the disturbance path is broken" "is-disturbed exited nonzero";; esac

echo "3. is-fast-failure needs BOTH halves (this is what protects the healthy path)"
for case_ in "rc1-short|{\"rc\":1,\"seconds\":0.4}|0|a cell that exited nonzero in 0.4s" \
             "rc1-long|{\"rc\":1,\"seconds\":60}|1|a SLOW failure is the operator's call, not the leg's" \
             "rc0-short|{\"rc\":0,\"seconds\":0.4}|1|a healthy smoke cell is short and must never match"; do
  n=${case_%%|*}; rest=${case_#*|}; j=${rest%%|*}; rest=${rest#*|}; want=${rest%%|*}; desc=${rest#*|}
  m=$(meta "$n" "$j"); python3 ./meta_tool.py is-fast-failure "$m" 5; got=$?
  [ "$got" = "$want" ] && ok "$desc" || bad "$desc" "wanted exit $want, got $got"
done

echo "4. a real shipped healthy Redis cell marks exactly as it did before"
src=$(ls -1 "$HOME"/tsan-atc26-artifact/data/perf/campaign-f3deebfbab60/primary/redis/*/run1/meta.json 2>/dev/null | head -1)
if [ -z "$src" ]; then bad "no shipped Redis cell found to re-mark" "looked under data/perf/campaign-f3deebfbab60/primary/redis"
else
  cp "$src" "$T/healthy.json"
  out=$(python3 ./meta_tool.py mark "$T/healthy.json" 0.10)
  case "$out" in ok) ok "mark says ok on $(basename "$(dirname "$(dirname "$src")")")/run1";; *) bad "a healthy shipped cell must still mark ok" "said: $out";; esac
  python3 ./meta_tool.py is-done "$T/healthy.json"; case $? in 0) ok "is-done says yes";; *) bad "a healthy cell must count as done" "is-done exited nonzero";; esac
  # Every key that existed before must be unchanged; only `failed` is new. A fix that quietly rewrote a
  # recorded field would invalidate the trees we ship.
  python3 - "$src" "$T/healthy.json" <<'PY' && ok "no recorded field changed (only 'failed' and 'gate_applied' added)" || bad "re-marking altered a recorded field" "see above"
import json, sys
a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
added = set(b) - set(a); changed = {k: (a[k], b[k]) for k in a if k in b and a[k] != b[k]}
if added - {"failed", "gate_applied"}: print("     unexpected new keys:", added - {"failed", "gate_applied"}); sys.exit(1)
if changed: print("     changed:", changed); sys.exit(1)
sys.exit(0)
PY
fi

echo "5. a leg that cannot measure stops instead of filling a matrix"
# THE FIXTURE MUST OWN ITS ROOT. lib.sh computes P5_ROOT as its own directory's ../.., and p5_binary
# builds every path from it, so a copy at <tmp>/perf puts P5_ROOT at /tmp and the fixture's stub binaries
# land in /tmp/nosql/redis/... -- OUTSIDE the temp directory, surviving the run. The suite then passed
# once and failed ever after, because 5a's pre-flight found the binaries 5b had left behind (seen for
# real: green at 04:56, two 5a checks red at 05:33 on an unchanged tree). Mirroring the repo layout under
# $T/root keeps P5_ROOT inside the sandbox, and the assertion below refuses to run if it ever escapes.
mkdir -p "$T/root/tools"; cp -r . "$T/root/tools/perf" 2>/dev/null
fixroot=$(cd "$T/root/tools/perf" && source ./lib.sh >/dev/null 2>&1 && echo "$P5_ROOT")
case "$fixroot" in
  "$T"/*) ok "the fixture's P5_ROOT is inside the sandbox ($fixroot)";;
  *) bad "the fixture would write outside its sandbox" "P5_ROOT=$fixroot, sandbox=$T"; echo; echo "$fails check(s) failed"; exit 1;;
esac
cat > "$T/root/tools/perf/bench_one.sh" <<'STUB'
#!/bin/bash
# Stub standing in for a build that is not there: exits nonzero at once, as the real one did on 22 Sep.
D="$4/$1/$2/${P5_RUN_PREFIX:-run}$3"; mkdir -p "$D"
printf '{"app":"%s","config":"%s","run":%s,"rc":2,"seconds":0.3,"outside_busy_share":0.0,"error":"no mysqld at ../mysql-%s/bin"}\n' "$1" "$2" "$3" "$2" > "$D/meta.json"
echo "$1 $2 run$3 rc=2 0.3s"; exit 2
STUB
chmod +x "$T/root/tools/perf/bench_one.sh"
# 5a. A MISSING BINARY was already refused before any cell ran, and still is. Asserted here so the
# pre-flight cannot be removed unnoticed: it is the cheapest of the three stops and the only one that
# costs nothing at all.
out=$(cd "$T/root/tools/perf" && P5_OUT="$T/pre" P5_LOCK="$T/lock" P5_MACHINE_LOCK=true \
        ./run.sh redis deadbeefdead 5 --configs "cfgA cfgB" --cpuset "" --in-bench 2>&1); rc=$?
case "$rc:$out" in 1:*"missing binary for redis cfgA"*) ok "a missing binary is refused before the first cell";;
  *) bad "the pre-flight must refuse a missing binary" "exit $rc: $(printf '%s' "$out" | tail -1)";; esac
[ "$(find "$T/pre" -name meta.json 2>/dev/null | wc -l)" = 0 ] && ok "no cell was attempted" || bad "cells ran despite the missing binary" "found metas under $T/pre"

# 5b. THE DEFECT'S OWN SHAPE: the binaries are there and the pre-flight passes, and the WORKLOAD fails at
# run time -- a missing directory, as MySQL's was on 22 Sep. This is what used to fill the matrix.
( cd "$T/root/tools/perf" && source ./lib.sh && source ./configs.sh && for c in cfgA cfgB; do
    b=$(p5_binary redis "$c"); mkdir -p "$(dirname "$b")"; : > "$b"; chmod +x "$b"; done )
out=$(cd "$T/root/tools/perf" && P5_OUT="$T/out" P5_LOCK="$T/lock" P5_MACHINE_LOCK=true \
        ./run.sh redis deadbeefdead 5 --configs "cfgA cfgB" --cpuset "" --in-bench 2>&1); rc=$?
case $rc in 70) ok "the leg exits 70";; *) bad "the leg must stop with exit 70" "exited $rc";; esac
case "$out" in *"STOPPING THE LEG"*) ok "it says it is stopping";; *) bad "the stop must be loud" "no STOPPING THE LEG line";; esac
case "$out" in *"no mysqld at"*) ok "it quotes the cell's own reason";; *) bad "the reason must be quoted, not just the count" "reason absent";; esac
cells=$(find "$T/out" -name meta.json | wc -l)
[ "$cells" -le 3 ] && ok "$cells cells attempted, not the 10-cell matrix" || bad "the leg kept going" "$cells cells written"
[ -f "$T/out/redis/perf_redis.md" ] && bad "a table was written for a leg that measured nothing" "perf_redis.md exists" || ok "no table written"

echo
[ "$fails" = 0 ] && { echo "all checks passed"; exit 0; } || { echo "$fails check(s) failed"; exit 1; }
