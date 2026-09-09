#!/bin/bash
# stageB_topup.sh <hash> — final pass: bring every configuration of every application up to N, re-running only
# what is short. Runs after the last leg, so it cannot interleave with one; safe to run repeatedly.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh; source ./configs.sh
H=${1:?}; N=${N:-5}; OUT="${P5_TOPUP_OUT:-$P5_DIR/results/stageB-$H}"; export P5_OUT="$OUT" MYSQL_SECONDS="${MYSQL_SECONDS:-180}" FF_THREADS="${FF_THREADS:-4}"
# Foreign-activity gate, tightened from 0.25 to 0.10 on 2026-09-08: over this campaign's 286 clean runs, runs in
# the 0.10-0.20 band ran about 10 % slow while passing the old gate, and the effects under measurement are 1-4 %.
# quarantine_foreign.sh retires the runs already recorded above the new threshold so this pass re-runs them.
export P5_FOREIGN_MAX="${P5_FOREIGN_MAX:-0.10}"
./quarantine_foreign.sh "$OUT" "$P5_FOREIGN_MAX" >> "$OUT/quarantine.log" 2>&1
for app in memcached sqlite redis ffmpeg mysql; do
  [ -d "$OUT/$app" ] || continue
  short=""
  for c in $(ls -d "$OUT/$app"/*/ 2>/dev/null | xargs -n1 basename); do
    n=0
    for d in "$OUT/$app/$c"/run[0-9]*; do
      # strict: "run5.foreign-0.136" and "run5.disturbed.174437" are retired runs, not repetitions
      case "${d##*/}" in run[0-9]) ;; run[0-9][0-9]) ;; *) continue;; esac
      [ -f "$d/meta.json" ] || continue
      python3 -c "import json,sys;m=json.load(open('$d/meta.json'));sys.exit(0 if m.get('rc')==0 and not m.get('disturbed') else 1)" 2>/dev/null && n=$((n+1))
    done
    [ "$n" -lt "$N" ] && short="$short $c"
  done
  [ -n "$short" ] || { p5_log "top-up: $app already complete"; continue; }
  p5_log "top-up: $app ->$short"
  ./run.sh "$app" "$H" "$N" --configs "$short" >> "$OUT/run-$app.log" 2>&1 || p5_log "top-up run.sh $app exited non-zero"
  python3 aggregate.py "$OUT" --app "$app" > /dev/null 2>&1
done
python3 aggregate.py "$OUT" > /dev/null 2>&1; python3 write_readme_results.py results/stageB-d3bf9f8c39fe "$OUT" > /dev/null 2>&1
echo "STAGE-B-TOPUP DONE $(date -Iseconds)" >> "$OUT/pipeline.log"
