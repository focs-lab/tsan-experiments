#!/bin/bash
# check_shipped_comparison.sh [<artifact-root>] — does the shipped campaign still reproduce ITSELF?
#
# Runs compare_with_claims.py over the shipped campaign data as if it were an evaluator's run. If the
# numbers in PERFORMANCE.md no longer agree with the data it ships, that is a documentation defect the
# artifact can detect on its own, without a machine and without measuring anything.
#
# THE ROOT IS NOT NAMED perf-<app>-<stamp>, which is how the tool resolves the application, so five
# symlinks in a temp directory point at the same root under the five names it understands. (raised in
# construction, 2026-09-20.)
#
# WHAT IS ASSERTED, AND WHY NOT THE ROW COUNT. Two conditions: at least one row was judged, and none was
# outside. The count itself is PRINTED, not asserted: the shipped data is frozen but the document is not, so
# a configuration row added to the documents would change the count and fail a hardcoded 48 for a reason
# that is not a defect. Asserting "some rows judged" is what stops the vacuous pass, which is the failure
# that matters -- "0 judged, 0 outside" must never read as success.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# THE ROOT IS DERIVED FROM THIS SCRIPT'S OWN LOCATION, not from $HOME. Shipped, this file lives at
# <artifact>/harness/tools/perf/, so the artifact is three directories up -- which is true on the host AND
# inside the container, where HOME is /tmp and a $HOME-based default resolved to a path that does not
# exist (tested 2026-09-20: "no CLAIMS.md at /tmp/tsan-atc26-artifact/CLAIMS.md"). The $HOME location is
# kept as a second guess for running from a source checkout, and an explicit argument beats both.
ART="${1:-}"
if [ -z "$ART" ]; then
  for cand in "$(cd "$HERE/../../.." 2>/dev/null && pwd)" "$HOME/tsan-atc26-artifact"; do
    [ -n "$cand" ] && [ -f "$cand/CLAIMS.md" ] && { ART="$cand"; break; }
  done
  [ -n "$ART" ] || { echo "cannot find the artifact root: tried $HERE/../../.. and $HOME/tsan-atc26-artifact" >&2
                     echo "  pass it as the first argument" >&2; exit 2; }
fi
CLAIMS="$ART/PERFORMANCE.md"
ROOT=$(ls -d "$ART"/data/perf/campaign-*/primary 2>/dev/null | head -1)
[ -f "$CLAIMS" ] || { echo "no PERFORMANCE.md at $CLAIMS" >&2; exit 2; }
[ -n "$ROOT" ]   || { echo "no data/perf/campaign-*/primary under $ART" >&2; exit 2; }

# THE TWO FILES AGREE BY CONVENTION; THIS MAKES THE CONVENTION FAIL BY NAME. compare_with_claims.py finds
# the summary table by its header "| config | label |", because the per-test table above it begins the same
# way and can have the same number of cells. If aggregate.py ever renames that header, every shipped table
# becomes "NO TABLE (the leg produced none)" -- loud, but indistinguishable from an empty tree, and the
# reader would look at the data rather than at the header. Checked here so a rename is reported as a
# rename. (suggested in review, 2026-09-22.)
HDR='| config | label |'
missing=0
for app in redis memcached sqlite ffmpeg mysql; do
  [ -d "$ROOT/$app" ] || continue
  t="$ROOT/perf_$app.md"
  if [ ! -f "$t" ]; then
    echo "FAIL: $ROOT/$app exists but $t does not: the leg shipped cells without its table." >&2
    missing=1; continue
  fi
  grep -qF "$HDR" "$t" || {
    echo "FAIL: $t has no '$HDR' header." >&2
    echo "      compare_with_claims.py finds the summary table by that header; aggregate.py must still emit it." >&2
    missing=1; }
done
[ "$missing" = 0 ] || exit 1

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
links=()
for app in redis memcached sqlite ffmpeg mysql; do
  [ -d "$ROOT/$app" ] || continue
  ln -s "$ROOT" "$TMP/perf-$app-shipped"
  links+=("$TMP/perf-$app-shipped")
done
[ ${#links[@]} -gt 0 ] || { echo "no application directories under $ROOT" >&2; exit 2; }

out=$(python3 "$HERE/compare_with_claims.py" "$CLAIMS" "${links[@]}" 2>&1); rc=$?
echo "$out"
judged=$(printf '%s\n' "$out" | sed -n 's/^\([0-9][0-9]*\) rows judged.*/\1/p' | tail -1)
outside=$(printf '%s\n' "$out" | sed -n 's/^[0-9][0-9]* rows judged, \([0-9][0-9]*\) outside.*/\1/p' | tail -1)
echo
if [ -z "${judged:-}" ] || [ "${judged:-0}" -eq 0 ]; then
  echo "FAIL: no rows were judged. The shipped data was not compared with anything, which is not a pass."
  exit 1
fi
if [ "${outside:-1}" -ne 0 ]; then
  echo "FAIL: $outside of $judged shipped rows fall outside the intervals PERFORMANCE.md prints for them."
  echo "      The documents and the data they ship disagree; one of them is wrong."
  exit 1
fi
echo "ok: $judged shipped rows judged, none outside — PERFORMANCE.md agrees with the data it ships."
