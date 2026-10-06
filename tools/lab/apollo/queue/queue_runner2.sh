#!/bin/bash
# queue_runner2.sh <A|B> [current-file] — runs the leg files queued in ~/p5-apollo/queue/<half>/ one after another on that
# apollo half, each as p5-apollo-tierb-<half> (MemoryMax 40G, no swap, NUMA-bound) with its watchdog (2 GB swap allowance).
# A leg counts as FAILED if the watchdog log shows "STOPPING p5-apollo-tierb-<half>" after its launch (a watchdog stop
# leaves Result=success, which fooled queue_runner.sh at 17:31) or its Result is not success; a failed leg is re-run
# (legs resume) once the 1-min load has stayed < 20 for 10 min. If [current-file] is given and the half is idle at start,
# it is (re)launched first. Files are data: add NN-name.sh files any time.
H=${1:?A|B}; Q=$HOME/p5-apollo/queue/$H; LOG=$HOME/p5-apollo/queue/queue-$H.log; mkdir -p $Q/done
node=$([ $H = A ] && echo 0 || echo 1); U=p5-apollo-tierb-$H; WDLOG=$HOME/p5-apollo/watchdog.log
say() { echo "[$(date '+%F %T')] $*" >> $LOG; }
quiet() { local q=0; while [ $q -lt 18 ]; do l=$(cut -d' ' -f1 /proc/loadavg); a=$(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo); awk -v l="$l" -v a="$a" 'BEGIN{exit !(l<48 && a>50)}' && q=$((q+1)) || q=0; sleep 10; done; }   # 3 min of load < 48 (foreign work is confined to CCD0) and > 50 GB available
wd_stopped_since() {   # <epoch> -> 0 if the watchdog stopped $U after it
  awk -v u="STOPPING $U:" -v t0="$1" 'index($0,u){ts=substr($0,2,19); gsub(/[-:]/," ",ts); if (mktime(ts) >= t0) f=1} END{exit !f}' "$WDLOG"
}
launch() {   # <file>
  systemctl --user reset-failed "$U" "$U-watchdog" 2>/dev/null
  systemd-run --user --unit $U -p MemoryMax=40G -p MemorySwapMax=0 -p NUMAPolicy=bind -p NUMAMask=$node -p WorkingDirectory=$HOME/p5-apollo \
    --setenv=HOME=$HOME --setenv=PATH=/usr/lib/llvm-18/bin:/usr/local/bin:/usr/bin:/bin bash "$1" >> $LOG 2>&1
  sleep 2
  systemd-run --user --unit $U-watchdog --setenv=HOME=$HOME --setenv=WD_MAX_SWAP_GROWTH_GB=2 $HOME/p5-apollo/apollo_watchdog.sh $U >> $LOG 2>&1
  CUR=$1; T0=$(date +%s); say "started $(basename $1)"
}
CUR="${2:-}"; T0=$(date +%s)
say "queue runner v2 for half $H starts (current: ${CUR:-none})"
if [ -n "$CUR" ] && ! systemctl --user is-active -q $U; then launch "$CUR"; fi
while :; do
  while systemctl --user is-active -q $U; do sleep 30; done
  sleep 5
  r=$(systemctl --user show -p Result --value $U 2>/dev/null)
  if [ -n "$CUR" ] && { wd_stopped_since $T0 || [ "$r" != success ]; }; then
    say "$(basename $CUR) was stopped (watchdog or Result=$r): waiting for a quiet apollo, then re-running it"; quiet; launch "$CUR"; continue
  fi
  [ -n "$CUR" ] && say "$(basename $CUR) finished"; CUR=""
  next=$(ls $Q/*.sh 2>/dev/null | sort | head -1)
  if [ -z "$next" ]; then sleep 60; continue; fi
  mv "$next" $Q/done/ && launch "$Q/done/$(basename $next)"
done
