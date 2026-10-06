#!/bin/bash
# leg_host.sh <leg> <hash12> <root> <app> <half 1|2> <arm>... — one timed leg on one host half (approved 25 Sep, for
# two concurrent pinned host legs). arm = NAME:TREE:CONFIG[:RUNTIME_OPTS], tree under ${LAB_DATA:-/extra/$USER}/<leg>-2026-09-25/trees/<TREE>.
# ONE discarded warm-up (first arm), N = 3, arms rotated per pass; cells unwrapped (the unit sets P5_MACHINE_LOCK=true; one outer
# exclusive hold covers the session); outside share recorded only; readout per the 18:45 rule.
set -uo pipefail
LEG=${1:?leg}; H=${2:?hash}; ROOT=${3:?root}; APP=${4:?app}; HALF=${5:?half}; shift 5; ARMS=("$@")
L=${LAB_DATA:-/extra/$USER}/$LEG-2026-09-25; TAG=${LEG_TAG:-}
# Filler legs (LEG_TAG fill*, unmeasured; cov1 27 Sep 21:0x): a fresh tag per invocation. With one shared tag every filler leg after the first found
# its runs "done" and returned at once, so the half it should keep busy went idle (apollo 20:57).
case "$TAG" in fill*) TAG="$TAG-$(date +%H%M%S)";; esac
# Stop list (cov1, 28 Sep 04:0x): a leg whose LEG_TAG is listed in STOP_TAGS exits at once unless POST4=1 (post4.sh runs those legs as two chains).
if [ -n "$TAG" ] && [ -z "${POST4:-}" ] && grep -qx -- "$TAG" ${LAB_DATA:-/extra/$USER}/cov1-2026-09-27/STOP_TAGS 2>/dev/null; then echo "leg_host: LEG_TAG $TAG on STOP_TAGS - skipped (post4 runs it)" >&2; exit 0; fi
# Hand-over (cov1, 28 Sep 05:3x; never SQLite beside MySQL on focs): post4's chains (POST4=1 without POST5=1) skip every "<tag> <app>"
# listed in P4_HANDOVER; post5.sh runs those legs from one pool with a MySQL/SQLite exclusion.
if [ -n "${POST4:-}" ] && [ -z "${POST5:-}" ] && grep -qx -- "$TAG $APP" ${LAB_DATA:-/extra/$USER}/cov1-2026-09-27/P4_HANDOVER 2>/dev/null; then echo "leg_host: $TAG $APP handed over to post5 - skipped" >&2; exit 0; fi
# Defer (cov1, 28 Sep 08:2x; build window opens after the FFmpeg singles, coverage before cleanliness): post5 (POST5=1 without POST6=1)
# skips every "<tag> <app>" in P5_DEFER; post6.sh runs them after the window.
if [ -n "${POST5:-}" ] && [ -z "${POST6:-}" ] && grep -qx -- "$TAG $APP" ${LAB_DATA:-/extra/$USER}/cov1-2026-09-27/P5_DEFER 2>/dev/null; then echo "leg_host: $TAG $APP deferred to post6 - skipped" >&2; exit 0; fi
LOG=$L/$LEG$TAG-$APP.log
# Pause gate (26 Sep 12:1x): a leg waits here, before its first cell, while ${LAB_DATA:-/extra/$USER}/HOST_PAUSE exists - so a build window can be cut in between
# the legs of a running chain without killing a cell.
# HOST_PAUSE.<owner> (28 Sep 11:4x): one pause file per owner, so one owner removing its HOST_PAUSE cannot release another owner's hold.
# LEG_OWN_PAUSE (29 Sep 01:5x): a leg inserted into a running chain holds its own HOST_PAUSE.<owner> and ignores only that file here.
# LEG_IGNORE_PAUSES (29 Sep 07:0x, half-1 legs beside another user's non-build VS Code node, if the probe cell passes rule (c)): pause files ignored here.
others_pause() { local f; for f in ${LAB_DATA:-/extra/$USER}/HOST_PAUSE ${LAB_DATA:-/extra/$USER}/HOST_PAUSE.*; do [ -e "$f" ] && [ "$f" != "${LEG_OWN_PAUSE:-}" ] && [[ " ${LEG_IGNORE_PAUSES:-} " != *" $f "* ]] && return 0; done; return 1; }
# Per-leg hold (29 Sep 08:0x): ${LAB_DATA:-/extra/$USER}/cov1-2026-09-27/HOLD_<leg><tag>_<app> holds just that leg before its first cell (batch 11 focs MySQL
# waits for the aligned-program verification).
while [ -e "${LAB_DATA:-/extra/$USER}/cov1-2026-09-27/HOLD_${LEG}${TAG}_${APP}" ]; do echo "[$(date '+%F %T')] $LEG$TAG $APP: held by HOLD_${LEG}${TAG}_${APP}" >&2; sleep 30; done
while others_pause; do echo "[$(date '+%F %T')] $LEG$TAG $APP: waiting for ${LAB_DATA:-/extra/$USER}/HOST_PAUSE to go" >&2; sleep 15; done
case $HALF in 1) CPUSET=4-27,60-83; IGN=28-51,84-107;; 2) CPUSET=28-51,84-107; IGN=4-27,60-83;; *) exit 2;; esac
say() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
# Refuse before the first cell when the leg dir or an arm's tree is missing (apollo's copy ran every cell against nothing and printed
# DONE, 26 Sep 08:26).
[ -d "$L" ] || { echo "REFUSED: leg dir $L does not exist" >&2; exit 2; }
# Runtime-option whitelist (4 Oct 2026): the TSan runtime accepts misspelled options silently, so an arm whose 4th field
# names a phase_guard* option the runtime does not define would run with the option silently off. Allowed: the three
# defined by the final runtime (phase_guard, phase_guard_stats, phase_guard_ranges); phase_guard_test_mutant is a test knob.
for a in "${ARMS[@]}"; do x=$(echo "$a" | cut -d: -f4-); for o in $(echo "$x" | tr ', ' '\n\n' | sed -n 's/^\(phase_guard[a-z_]*\)=.*/\1/p'); do
  case "$o" in phase_guard|phase_guard_stats|phase_guard_ranges) ;; *) echo "REFUSED: arm $a: runtime option '$o' is not a known phase_guard option"; exit 2;; esac; done; done
for a in "${ARMS[@]}"; do t=$(echo "$a" | cut -d: -f2); [ -d "$L/trees/$t/tsan-experiments/tools/perf" ] || { echo "REFUSED: arm $a: no tree $L/trees/$t/tsan-experiments" | tee -a "$LOG" >&2; exit 2; }; done
# Co-runner rule (26 Sep ~03:40; pre-registered from then on): every cell logs the OTHER half's busy share during
# the cell; the leg declares CORUNNER=busy|idle in advance; a cell whose measured state differs (busy < 0.05 declared busy, > 0.05
# declared idle; idle threshold 0.02 from 26 Sep 20:25, pre-registered: clean idle halves read 0.001-0.004 on every app, the x265 spill
# read 0.043-0.046 and passed 0.05) is marked MISMATCH in <run dir>/corunner.txt and excluded, or forms its own block, in both readouts.
corun_after() {
  local st d m=ok; st=$(python3 ${LAB_DATA:-/extra/$USER}/corunner.py "$IGN" "$L/.corun-$HALF.json")
  case "${CORUNNER:-none}/$st" in */n/a) m=unknown;; busy/*) awk "BEGIN{exit !($st<0.05)}" && m=MISMATCH;; idle/*) awk "BEGIN{exit !($st>0.02)}" && m=MISMATCH;; esac
  d=$(ls -td "$R"/tools/perf/results/$LEG$TAG-$N-$H/$APP/*/run* 2>/dev/null | head -1)
  say "corunner: other half ($IGN) busy $st during the cell; declared ${CORUNNER:-none}; $m"
  [ -n "$d" ] && echo "other_half=$IGN busy=$st declared=${CORUNNER:-none} verdict=$m" > "$d/corunner.txt"
}
cell() {
  IFS=: read -r N T C X <<< "$1"; R=$L/trees/$T/tsan-experiments
  # Per-arm compiler (batched component legs, 26 Sep: each component arm comes from its own root): ARM_HASH_<NAME> / ARM_ROOT_<NAME>
  # override the leg's hash and root for that arm only (the provenance gate checks each binary against its own arm's hash).
  local H=$H ROOT=$ROOT hv="ARM_HASH_$N" rv="ARM_ROOT_$N"; [ -n "${!hv:-}" ] && H=${!hv}; [ -n "${!rv:-}" ] && ROOT=${!rv}
  say "$APP half $HALF arm $N pass $2 ($C${X:+, $X})"
  python3 ${LAB_DATA:-/extra/$USER}/corunner.py "$IGN" "$L/.corun-$HALF.json" > /dev/null
  # FFmpeg cells run in a cgroup cpuset of the half (26 Sep 20:1x): libx265's thread pool calls sched_setaffinity to whole NUMA nodes
  # and sizes itself from the machine's CPU count, so under taskset alone h265 ran ~112 pool threads over all CPUs (the other half read busy 0.044
  # in every idle-declared FFmpeg cell, vs 0.002 for MySQL). The kernel intersects x265's mask with AllowedCPUs; other apps are unchanged.
  local SCOPE=(); [ "$APP" = ffmpeg ] && SCOPE=(systemd-run --user --scope --quiet -p AllowedCPUs="$CPUSET" -p MemoryMax=80G -p MemorySwapMax=0 --)
  ( cd "$R/tools/perf" && env -u LLVM_ROOT_PATH -u LLVM_PATH -u CFLAGS -u CXXFLAGS -u LDFLAGS HOME=$HOME PATH=/usr/lib/llvm-18/bin:/usr/bin:/bin \
      LLVM_TSAN_ROOT=$ROOT P5_HASH=$H P5_INSTALL_ROOT=$R/installs P5_OUT=$R/tools/perf/results/$LEG$TAG-$N-$H \
      P5_LOCK=/tmp/p5-bench-$LEG-half$HALF.lock P5_IGNORE_CPUS=$IGN P5_FOREIGN_MAX=1.0 FF_THREADS=4 ART_MEMCACHED_PORT=7778 MYSQL_SECONDS=60 \
      SQLITE_TESTS="${LEG_SQLITE_TESTS:-walthread1 walthread2 dynamic_triggers checkpoint_starvation_1 checkpoint_starvation_2 stress1 stress2}" \
      TSAN_OPTIONS="report_bugs=0${X:+ $X}" TSAN_OPTIONS_EXTRA="${X:-}" TSAN_OPTIONS_OVERRIDE="report_bugs=0 verbosity=0${X:+ $X}" \
      "${SCOPE[@]}" ./run.sh "$APP" "$H" "$4" --warmup "$3" --configs "$C" --cpuset "$CPUSET" >> "$LOG" 2>&1 ); local rc=$?; [ $rc = 0 ] || say "$APP arm $N pass $2 rc=$rc"
  corun_after
  # Fail fast (29 Sep 22:5x, standing): a cell fails if run.sh returned non-zero, no run dir appeared, or the harness wrote a non-empty
  # cell_error.txt (no parsed throughput). Two consecutive failed cells stop the leg with a FAIL-FAST line (exit 3) - no leg runs to its end without data.
  [ "${4:-1}" = 0 ] && return 0   # warm-up call (N=0) writes no run dir: not a cell for fail-fast
  local d; d=$(ls -td "$R"/tools/perf/results/$LEG$TAG-$N-$H/$APP/*/run* 2>/dev/null | head -1)
  if [ $rc != 0 ] || [ -z "$d" ] || [ -s "$d/cell_error.txt" ]; then FF=$((FF+1)); say "cell failed ($APP arm $N pass $2: rc=$rc$([ -s "$d/cell_error.txt" ] && echo ", $(head -1 "$d/cell_error.txt")")); consecutive $FF"
  else FF=0; fi
  [ $FF -ge 2 ] && { say "FAIL-FAST: LEG $LEG$TAG $APP FAILED - stopped after $FF consecutive failed cells"; touch "${LAB_DATA:-/extra/$USER}/cov1-2026-09-27/FAILFAST_$LEG${TAG}_$APP"; exit 3; }
  return 0
}
FF=0
n=${#ARMS[@]}; step=$(( n / 3 )); [ $step -lt 1 ] && step=1
if [ "$n" = 2 ]; then
  # Two-arm legs (26 Sep 03:3x; experiments.md s1): a warm-up of BOTH arms, then N = 4 in ABBA / BAAB order, each
  # arm leading twice. The plain rotation put the first arm first in 2 of 3 passes, right after its own warm-up, which could
  # favour it systematically (U2 read 0.96-1.00 of T1 on all four apps, 26 Sep).
  say "LEG $LEG$TAG $APP START on host half $HALF ($CPUSET, ignoring $IGN): arms ${ARMS[*]}; co-runner declared ${CORUNNER:-none}; warm-up of BOTH arms, N=4, ABBA/BAAB (each arm leads twice)"
  cell "${ARMS[0]}" 0 1 0; cell "${ARMS[1]}" 0 1 0
  for k in 1 2 3 4; do case $k in 1|4) o="0 1";; *) o="1 0";; esac; for i in $o; do cell "${ARMS[$i]}" $k 0 $k; done; done
  say "LEG $LEG$TAG $APP DONE"; exit 0
fi
NP=${LEG_N:-3}   # passes of a rotated leg (LEG_N, 28 Sep: N=4 for the c7 FE-SINK legs; default 3 = the order below, unchanged)
say "LEG $LEG$TAG $APP START on host half $HALF ($CPUSET, ignoring $IGN): arms ${ARMS[*]}; co-runner declared ${CORUNNER:-none}; one warm-up, N=$NP, rotated"
cell "${ARMS[0]}" 0 1 0
# WARM_ALL=1 (26 Sep: QUIET and the batched multi-arm component legs): a warm-up of EVERY arm, not only the first.
if [ "${WARM_ALL:-0}" = 1 ]; then say "warm-up of every arm (WARM_ALL=1)"; for ((i=1;i<n;i++)); do cell "${ARMS[$i]}" 0 1 0; done; fi
# Pass order (25 Sep 20:19; applies to every leg STARTED after this change): pass 1 forward, pass 2 BACKWARD
# (reversed order, shift s2 = step, or step+1 where step would put the warm-up arm first again), pass 3 forward with shift
# 2*step, so every arm gets two different predecessors. Pairs (n <= 2) keep the plain rotation: reversing a pair would put
# the same arm first in every pass.
s2=$step; [ $(( (n - 1 + s2) % n )) = 0 ] && s2=$(( step + 1 ))
# k > 3 (LEG_N): even passes run backward, each shifted a further 2*step; odd passes forward with shift (k-1)*step. k <= 3 is unchanged.
idx() { local k=$1 i=$2; if [ $((k % 2)) = 0 ] && [ "$n" -gt 2 ]; then echo $(( (n - 1 - i + s2 + (k/2 - 1)*2*step) % n )); else echo $(( (i + (k-1)*step) % n )); fi; }
say "pass order: pass 1 forward, pass 2 backward (shift $s2), pass 3 forward (n > 2)$([ $NP -gt 3 ] && echo ", pass 4 backward (shift $((s2 + 2*step)))"); pairs rotate"
for ((k=1;k<=NP;k++)); do for ((i=0;i<n;i++)); do cell "${ARMS[$(idx $k $i)]}" $k 0 $k; done; done
say "LEG $LEG$TAG $APP DONE"
