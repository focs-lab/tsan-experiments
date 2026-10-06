#!/bin/bash
# final_aggregate.sh — the campaign's tables, produced the one way that is correct.
# Usage: ./final_aggregate.sh [results/campaign-<hash>]
#
# TWO THINGS THIS EXISTS TO STOP BEING REDISCOVERED.
#
# 1. `aggregate.py --app X` rewrites perf_summary.md with ONLY that application's rows. Aggregating the
#    applications one at a time therefore leaves a summary containing the last one, and the earlier rows
#    are gone without a warning -- it happened on 2026-09-16 with redis followed by memcached. Every
#    invocation below names every application it found.
# 2. Both run ranges are wanted for every row: all five runs, and runs 2-5. The second is what says whether
#    the discarded warm-up actually removed run1's cold-start penalty; the two tables AGREEING is the
#    evidence, so the comparison only exists if both are computed. Outputs are suffixed, so neither pass
#    overwrites the other.
#
# Each results root is aggregated separately because the r2 tree holds the second-concurrency rows
# (memcached 112 threads, MySQL 84, Redis c=112) and mixing them into the primary table would silently
# compare rows taken at different concurrency.
set -uo pipefail
cd "$(dirname "$0")"
R="${1:-results/campaign-f3deebfbab60}"
[ -d "$R" ] || { echo "no results root at $R" >&2; exit 2; }

for sub in primary r2; do
  root="$R/$sub"
  [ -d "$root" ] || { echo "skip $sub (not present)"; continue; }
  apps=""
  for a in memcached redis sqlite mysql ffmpeg; do
    [ -d "$root/$a" ] && apps="$apps --app $a"
  done
  [ -n "$apps" ] || { echo "skip $sub (no application directories)"; continue; }
  echo "=== $sub:$(echo "$apps" | sed 's/--app//g') ==="
  # shellcheck disable=SC2086
  python3 ./aggregate.py "$root" $apps          || echo "  AGGREGATION FAILED for $sub (all runs)" >&2
  # shellcheck disable=SC2086
  python3 ./aggregate.py "$root" $apps --runs 2-5 || echo "  AGGREGATION FAILED for $sub (runs 2-5)" >&2
done

echo
echo "tables written:"
find "$R" -maxdepth 2 -name 'perf_summary*.md' -o -maxdepth 2 -name 'perf_*.md' | sort | sed 's/^/  /'
echo
# A summary whose row count does not match the configurations on disk means an application was dropped --
# the exact failure this script exists to prevent, so it is checked rather than assumed.
for sub in primary r2; do
  s="$R/$sub/perf_summary.md"; [ -f "$s" ] || continue
  want=$(find "$R/$sub" -mindepth 2 -maxdepth 2 -type d -not -name 'run*' -not -name 'warmup*' 2>/dev/null | wc -l)
  # Count DATA rows by naming the applications. '^| [a-z]' also matches the table's own header row,
  # "| app | config | ... |", which made this check report a mismatch of exactly one on its first real run.
  got=$(grep -cE '^\| (memcached|redis|sqlite|mysql|ffmpeg) \|' "$s" 2>/dev/null || echo 0)
  printf '  %s: %s configuration rows in the summary, %s configuration directories on disk  %s\n' \
    "$sub" "$got" "$want" "$([ "$got" = "$want" ] && echo ok || echo '<<< MISMATCH: an application was dropped')"
done
