#!/bin/bash
# export_campaign.sh [dest] — copy the campaign's results into the artifact as shippable data.
# Default dest: ~/tsan-atc26-artifact/data/perf/campaign-f3deebfbab60
#
# WHAT SHIPS AND WHAT DOES NOT, and why each exclusion is a decision rather than an oversight:
#
#   primary/ and r2/        ship. These are what every performance claim rests on, and 91 checks them
#                           STRICTLY, so they must be non-empty for its exit 0 to mean anything.
#   oldclip-not-shipped/    does NOT ship. Camera-ready evidence only: it uses WatchingEyeTexture.mkv,
#                           which cannot be redistributed, so no reader could reproduce it. It lives
#                           outside the aggregation path for the same reason -- a label tells a reader
#                           not to use it, being absent stops it arriving in a table by momentum.
#   sound-rows/             does NOT ship as a results root. It is three builds, not measurements; its
#                           static counts belong with the static data, not under data/perf.
#   compile-time-*/         does NOT ship here. Compile time is its own claim with its own script.
#   build/ logs             do not ship. Large, and build_info.txt carries what is attributable.
#
# The copy is by RULE, not by hand: everything under a shipping root except the excluded patterns, so a
# file nobody thought about ships rather than being silently dropped. Verified afterwards by counting
# runs at source and destination and by running the provenance check on what landed.
set -uo pipefail
cd "$(dirname "$0")"
SRC="$(pwd)/results/campaign-f3deebfbab60"
DEST="${1:-$HOME/tsan-atc26-artifact/data/perf/campaign-f3deebfbab60}"
HASH=f3deebfbab60
[ -d "$SRC" ] || { echo "no campaign tree at $SRC" >&2; exit 2; }

EXCLUDES=(--exclude='build/' --exclude='*.raw' --exclude='__pycache__/')
mkdir -p "$DEST"
for sub in primary r2; do
  [ -d "$SRC/$sub" ] || { echo "missing $sub in the campaign tree" >&2; exit 2; }
  rsync -a "${EXCLUDES[@]}" "$SRC/$sub/" "$DEST/$sub/"
done
# static counts and the campaign log travel with the data they describe
for f in static-counts.csv builds.log legs.log foreign-windows.log; do
  [ -f "$SRC/$f" ] && cp -p "$SRC/$f" "$DEST/"
done

# --- verify what landed, rather than trusting rsync ---
fail=0
for sub in primary r2; do
  a=$(find "$SRC/$sub" -name meta.json -path '*/run*' | wc -l)
  b=$(find "$DEST/$sub" -name meta.json -path '*/run*' | wc -l)
  printf '  %-8s runs at source %4s, at destination %4s  %s\n' "$sub" "$a" "$b" \
    "$([ "$a" = "$b" ] && echo ok || { echo '<<< COUNT MISMATCH'; fail=1; })"
done
# the exclusions must have excluded, and the non-shipping roots must be absent
for pat in oldclip-not-shipped sound-rows compile-time-memcached; do
  n=$(find "$DEST" -maxdepth 1 -name "$pat" | wc -l)
  printf '  %-26s present in export: %s  %s\n' "$pat" "$n" "$([ "$n" = 0 ] && echo ok || { echo '<<< MUST NOT SHIP'; fail=1; })"
done
echo
python3 ./verify_provenance.py --expect="$HASH" "$DEST/primary" "$DEST/r2" || fail=1
[ "$fail" = 0 ] || { echo; echo "EXPORT NOT CLEAN — see above. The shipped data is only as good as this check."; exit 1; }
echo; echo "export ok -> $DEST"
