#!/bin/bash
# quarantine_foreign.sh <results-root> <threshold> [apps...] — retire runs whose foreign-CPU activity exceeded a
# threshold, so the top-up pass re-runs them.
#
# Why 0.25 was too loose. Over the 286 clean runs of this campaign, run duration relative to the configuration's
# own median rises with the busy share of the CPUs outside our pinned set (r = 0.77):
#     [0.00, 0.02) n=189  1.0000     [0.05, 0.10) n=5  1.0115     [0.20, 1.01) n=5  1.6458
#     [0.02, 0.05) n= 79  1.0000     [0.10, 0.20) n=8  1.0986
# Every run in the 0.10-0.20 band passed the 0.25 gate and was averaged in, while running about 10 % slow. The
# effects under measurement are 1-4 %, so the gate has to sit below the band where a visible effect starts.
# The criterion is the recorded foreign activity, applied uniformly to every application of the tree.
set -uo pipefail; cd "$(dirname "$0")"
ROOT=${1:?results root}; TH=${2:-0.10}; shift 2 || true; APPS=${*:-"memcached sqlite redis ffmpeg mysql"}
n=0
for app in $APPS; do
  [ -d "$ROOT/$app" ] || continue
  for d in "$ROOT/$app"/*/run[0-9]*; do
    [ -d "$d" ] || continue; case "$d" in *.disturbed.*|*.stall-*|*.foreign-*) continue;; esac
    f="$d/meta.json"; [ -f "$f" ] || continue
    o=$(python3 -c "import json,sys;m=json.load(open('$f'));print(m.get('outside_busy_share') or 0)" 2>/dev/null) || continue
    keep=$(python3 -c "print(1 if float('$o') < float('$TH') else 0)")
    [ "$keep" = 1 ] && continue
    nd="$d.foreign-$(printf '%.3f' "$o")"
    mv "$d" "$nd" || continue
    # Mark it in the record too. Renaming alone is not enough: a consumer that globs run[0-9]* still finds the
    # directory, and its meta.json would still read rc=0, disturbed=false, so the run would be counted as clean
    # and never re-run. The rename is for humans, the flag is for every reader.
    python3 - "$nd/meta.json" "$o" "$TH" <<'PY2' || true
import json, sys
p, o, th = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
m = json.load(open(p)); m["disturbed"] = True
m["retired_reason"] = f"foreign activity outside the pinned set {o:.4f} > gate {th:.2f}"
json.dump(m, open(p, "w"), indent=1)
PY2
    n=$((n+1)); echo "retired $nd (outside_busy=$o)"
  done
done
echo "retired $n run(s) above $TH in $ROOT"
