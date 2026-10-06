#!/bin/bash
# leg_apollo.sh <leg> <hash12> <root> <app> <half A|B> <arm>... — one timed leg on one apollo half.
# arm = NAME:TREE:CONFIG[:RUNTIME_OPTS]  (tree under ~/p5-apollo/<leg>/<TREE>/tsan-experiments; CONFIG as the harness names it)
# Protocol (as tier A, 25 Sep): ONE discarded warm-up (the first arm, before pass 1), N = 3 measured, arm order rotated per
# pass; outside share recorded only (P5_FOREIGN_MAX=1.0); readout per the 17:20 rule (primary + sensitivity).
set -uo pipefail
LEG=${1:?leg}; H=${2:?hash}; ROOT=${3:?root}; APP=${4:?app}; HALF=${5:?half}; shift 5; ARMS=("$@")
L=$HOME/p5-apollo/$LEG; TAG=${LEG_TAG:-}; LOG=$L/$LEG$TAG-$APP.log   # LEG_TAG names a FRESH session (own results dirs)
case $HALF in A) CPUSET=8-15,40-47; IGN=16-31,48-63;; B) CPUSET=16-31,48-63; IGN=8-15,40-47;; *) exit 2;; esac
say() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
# 2 Oct: MySQL keeps binary logging ON (comparability), but its binlogs piled up across legs (89 GB, 3,304 x 1 GB since 25 Sep): purge them
# before each MySQL leg with mysqld down. The server recreates binlog.000001 at start; the first warm-up shows a clean start.
if [ "$APP" = mysql ] && ! pgrep -x mysqld >/dev/null; then d=${MYSQL_DATA_DIR:-/tmp/mysql-benchmarks-datadir}; n=$(ls $d 2>/dev/null | grep -c "^binlog\.[0-9]"); find $d -maxdepth 1 -name "binlog.[0-9]*" -delete 2>/dev/null; rm -f $d/binlog.index; mkdir -p $L; echo "[$(date '+%F %T')] binlog purge before the leg: $n files" >> "$LOG"; fi
# Refuse before the first cell when the leg dir or an arm's tree is missing: a queue item naming a leg dir that does not exist
# ran every cell against nothing and still printed DONE (26 Sep 08:26, "batch1r2").
[ -d "$L" ] || { echo "REFUSED: leg dir $L does not exist" >&2; exit 2; }
# Runtime-option whitelist (4 Oct 2026): the TSan runtime accepts misspelled options silently, so an arm whose 4th field
# names a phase_guard* option the runtime does not define would run with the option silently off. Allowed: the three
# defined by the final runtime (phase_guard, phase_guard_stats, phase_guard_ranges); phase_guard_test_mutant is a test knob.
for a in "${ARMS[@]}"; do x=$(echo "$a" | cut -d: -f4-); for o in $(echo "$x" | tr ', ' '\n\n' | sed -n 's/^\(phase_guard[a-z_]*\)=.*/\1/p'); do
  case "$o" in phase_guard|phase_guard_stats|phase_guard_ranges|phase_guard_selfoff_ms) ;; *) echo "REFUSED: arm $a: runtime option '$o' is not a known phase_guard option"; exit 2;; esac; done; done
for a in "${ARMS[@]}"; do t=$(echo "$a" | cut -d: -f2); [ -d "$L/$t/tsan-experiments/tools/perf" ] || { echo "REFUSED: arm $a: no tree $L/$t/tsan-experiments" | tee -a "$LOG" >&2; exit 2; }; done
# Co-runner rule (26 Sep ~03:40; pre-registered from then on): every cell logs the OTHER half's busy share during
# the cell; the leg declares CORUNNER=busy|idle in advance; a cell whose measured state differs (busy < 0.05 declared busy, > 0.05
# declared idle; idle threshold 0.02 from 26 Sep 20:25, pre-registered: clean idle halves read 0.001-0.004 on every app, the x265 spill
# read 0.043-0.046 and passed 0.05) is marked MISMATCH in <run dir>/corunner.txt and excluded, or forms its own block, in both readouts.
corun_after() {
  local st d m=ok; st=$(python3 $HOME/p5-apollo/queue/corunner.py "$IGN" "$L/.corun-$HALF.json")
  case "${CORUNNER:-none}/$st" in */n/a) m=unknown;; busy/*) awk "BEGIN{exit !($st<0.05)}" && m=MISMATCH;; idle/*) awk "BEGIN{exit !($st>$( [ $HALF = B ] && echo 0.03 || echo 0.02 ))}" && m=MISMATCH;; esac
  d=$(ls -td "$R"/tools/perf/results/$LEG$TAG-$N-$H/$APP/*/run* 2>/dev/null | head -1)
  # CCD0 (0-7,32-39; interactive work from 28 Sep 18:2x, shares node 0's memory with half A): cell-average busy share, recorded, never gated;
  # Half B idle limit 0.03 (29 Sep 01:3x: unpinned interactive sessions read ~0.02 on half A); half A keeps 0.02.
  # the per-5-s timeline is ~/p5-apollo/ccd0.log (ccd0_sampler.sh) - the readout flags cells with >= 3 samples >= 50 %.
  local c0; c0=$(python3 $HOME/p5-apollo/queue/corunner.py "0-7,32-39" "$L/.corun-ccd0-$HALF.json")
  say "corunner: other half ($IGN) busy $st during the cell; declared ${CORUNNER:-none}; $m; ccd0 busy $c0"
  [ -n "$d" ] && echo "other_half=$IGN busy=$st declared=${CORUNNER:-none} verdict=$m ccd0_busy=$c0" > "$d/corunner.txt"
}
cell() {   # <armspec> <k> <warmup> <N>
  IFS=: read -r N T C X <<< "$1"; R=$L/$T/tsan-experiments
  # Per-arm compiler (batched component legs, 26 Sep: each component arm comes from its own root): ARM_HASH_<NAME> / ARM_ROOT_<NAME>
  # override the leg's hash and root for that arm only (the provenance gate checks each binary against its own arm's hash).
  local H=$H ROOT=$ROOT hv="ARM_HASH_$N" rv="ARM_ROOT_$N"; [ -n "${!hv:-}" ] && H=${!hv}; [ -n "${!rv:-}" ] && ROOT=${!rv}
  say "$APP half $HALF arm $N pass $2 ($C${X:+, $X})"
  python3 $HOME/p5-apollo/queue/corunner.py "$IGN" "$L/.corun-$HALF.json" > /dev/null
  python3 $HOME/p5-apollo/queue/corunner.py "0-7,32-39" "$L/.corun-ccd0-$HALF.json" > /dev/null
  # 3 Oct 2026: FFmpeg in a cgroup cpuset scope, as leg_host.sh does. libx265 resets each worker thread's affinity, so taskset alone
  # let 38 of its threads run on the other half and on CCD0 (cov1ffamd2 stopped). FF_THREADS defaults to 4, as on focs.
  # BUT apollo's user manager is not delegated the cpuset controller (cgroup.controllers: cpu memory pids), so AllowedCPUs is
  # ignored here and x265 still escapes (69 of 92 threads outside half A inside the scope, 3 Oct 14:0x); only MemoryMax holds.
  # FIXED 3 Oct 14:2x: root added Delegate=cpu cpuset io memory pids for user@.service and enabled cpuset at runtime; after
  # systemctl --user daemon-reexec the scope holds (x265: 92/92 threads in half A, cpuset.cpus.effective 8-15,40-47).
  local SCOPE=(); [ "$APP" = ffmpeg ] && SCOPE=(systemd-run --user --scope --quiet -p AllowedCPUs="$CPUSET" -p MemoryMax=40G -p MemorySwapMax=0 --)
  ( cd "$R/tools/perf" && env FF_THREADS=${FF_THREADS:-4} HOME=$HOME PATH=$HOME/p5-apollo/bin:/usr/lib/llvm-18/bin:/usr/local/bin:/usr/bin:/bin SYSBENCH_SCRIPTS_DIR=$HOME/p5-apollo/share/sysbench MYSQL_SECONDS=${LEG_MYSQL_SECONDS:-60} LLVM_TSAN_ROOT=$ROOT P5_HASH=$H P5_BUILDS=$HOME/builds \
      P5_INSTALL_ROOT=$R/installs P5_OUT=$R/tools/perf/results/$LEG$TAG-$N-$H P5_LOCK=/tmp/p5-bench-$LEG-$HALF.lock P5_IGNORE_CPUS=$IGN \
      P5_FOREIGN_MAX=1.0 P5_NO_BUILD_SCOPE=1 ART_MEMCACHED_PORT=$([ $HALF = A ] && echo 7778 || echo 7779) \
      SQLITE_TESTS="${LEG_SQLITE_TESTS:-walthread1 walthread2 dynamic_triggers checkpoint_starvation_1 checkpoint_starvation_2 stress1 stress2}" \
      TSAN_OPTIONS="report_bugs=0${X:+ $X}" TSAN_OPTIONS_EXTRA="${X:-}" TSAN_OPTIONS_OVERRIDE="report_bugs=0 verbosity=0${X:+ $X}" \
      "${SCOPE[@]}" ./run.sh "$APP" "$H" "$4" --warmup "$3" --configs "$C" --cpuset "$CPUSET" >> "$LOG" 2>&1 ); local rc=$?; [ $rc = 0 ] || say "$APP arm $N pass $2 rc=$rc"
  corun_after
  # Fail fast (29 Sep 22:5x, standing): two consecutive failed cells (run.sh rc != 0, no run dir, or a non-empty cell_error.txt =
  # no parsed throughput) stop the leg with a FAIL-FAST ... FAILED line and exit 3. (Per-half memcached port since 22:5x: halves run in parallel.)
  [ "${4:-1}" = 0 ] && return 0   # warm-up call (N=0) writes no run dir: not a cell for fail-fast
  local d; d=$(ls -td "$R"/tools/perf/results/$LEG$TAG-$N-$H/$APP/*/run* 2>/dev/null | head -1)
  if [ $rc != 0 ] || [ -z "$d" ] || [ -s "$d/cell_error.txt" ]; then FF=$((FF+1)); say "cell failed ($APP arm $N pass $2: rc=$rc$([ -s "$d/cell_error.txt" ] && echo ", $(head -1 "$d/cell_error.txt")")); consecutive $FF"
  else FF=0; fi
  [ $FF -ge 2 ] && { say "FAIL-FAST: LEG $LEG$TAG $APP FAILED - stopped after $FF consecutive failed cells"; touch "$L/FAILFAST_$LEG${TAG}_$APP"; exit 3; }
  return 0
}
FF=0
# Rule (e) start gate (28 Sep 20:2x): a half-A leg does not start into CCD0 load. Wait until the last minute of ccd0.log (12 x 5 s)
# averages < 0.10 (cells >= 0.10 are retired at readout); a WAIT line every 10 min. Half B (socket 1) is not gated.
if [ "$HALF" = A ]; then w0=$(date +%s); wl=0
  while c=$(tail -n 12 $HOME/p5-apollo/ccd0.log 2>/dev/null | awk '{s+=$3;n++} END{if(n<12) print 1; else printf "%.3f", s/n}'); awk "BEGIN{exit !($c>=0.10)}"; do
    [ $(( $(date +%s) - wl )) -ge 600 ] && { say "WAIT (rule e): CCD0 busy $c over the last minute; half-A leg $LEG$TAG $APP not started"; wl=$(date +%s); }; sleep 30; done
  [ $wl -gt 0 ] && say "CCD0 quiet ($c); starting after $(( ($(date +%s) - w0) / 60 )) min"; fi
# Foreign-user gate (29 Sep 13:2x, prospective): a leg starts only when no process of a user other than the leg's own user has used more than 1 core
# in any 10-s window for 5 minutes (30 consecutive windows; foreign_gate.py). Rule (c) unchanged. A WAIT line every 10 min.
fq=0; fw=$(date +%s); fl=0
while [ $fq -lt 30 ]; do r=$(taskset -c 0-3 python3 $HOME/p5-apollo/queue/foreign_gate.py 10); c=${r%% *}
  if awk "BEGIN{exit !($c>1.0)}"; then fq=0; [ $(( $(date +%s) - fl )) -ge 600 ] && { say "WAIT (foreign-user gate): $r"; fl=$(date +%s); }; else fq=$((fq+1)); fi; done
[ $fl -gt 0 ] && say "foreign-user gate clear after $(( ($(date +%s) - fw) / 60 )) min"
n=${#ARMS[@]}; step=$(( n / 3 )); [ $step -lt 1 ] && step=1
if [ "$n" = 2 ]; then
  # Two-arm legs (26 Sep 03:3x; experiments.md s1): a warm-up of BOTH arms, then N = 4 in ABBA / BAAB order, each
  # arm leading twice. The plain rotation put the first arm first in 2 of 3 passes, right after its own warm-up, which could
  # favour it systematically (U2 read 0.96-1.00 of T1 on all four apps, 26 Sep).
  say "LEG $LEG$TAG $APP START on apollo half $HALF ($CPUSET): arms ${ARMS[*]}; co-runner declared ${CORUNNER:-none}; warm-up of BOTH arms, N=${LEG_N:-4}, ABBA/BAAB"
  cell "${ARMS[0]}" 0 1 0; cell "${ARMS[1]}" 0 1 0
  NP2=${LEG_N:-4}   # LEG_N (28 Sep 19:2x): ABBA/BAAB repeated; k mod 4 in {1,0} -> A B, else B A (N=6: each arm leads 3 times)
  for ((k=1;k<=NP2;k++)); do case $((k % 4)) in 1|0) o="0 1";; *) o="1 0";; esac; for i in $o; do cell "${ARMS[$i]}" $k 0 $k; done; done
  say "LEG $LEG$TAG $APP DONE"; exit 0
fi
NP=${LEG_N:-3}   # passes of a rotated leg (LEG_N, 28 Sep: N=4 for the c7 FE-SINK legs; default 3 = the order below, unchanged)
say "LEG $LEG$TAG $APP START on apollo half $HALF ($CPUSET): arms ${ARMS[*]}; co-runner declared ${CORUNNER:-none}; one warm-up, N=$NP, rotated"
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
say "pass order: pass 1 forward, pass 2 backward (shift $s2), pass 3 forward (n > 2); pairs rotate"
for ((k=1;k<=NP;k++)); do for ((i=0;i<n;i++)); do cell "${ARMS[$(idx $k $i)]}" $k 0 $k; done; done
say "LEG $LEG$TAG $APP DONE"
