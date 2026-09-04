#!/bin/bash
# Archive stale result trees, paper-era builds and traces from the SSD into /extra (tar+zstd), verify, delete.
# Usage: ./cleanup_archive.sh [--dry-run]   (list in ARCHIVE_PATHS below; approved by Alexey 2026-09-04)
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO=$PWD; DEST=/extra/alexey/tsan-experiments/archive-2026-09; DRY=${1:-}
ARCHIVE_PATHS=(
  nosql/memcached/results.25.11 nosql/memcached/results.Nov27 nosql/memcached/results.good.March6
  nosql/memcached/old nosql/memcached/old-6march nosql/memcached/old-builds
  nosql/redis/__results_redis__bak nosql/redis/__results_redis__bak2 nosql/redis/__results_redis__bak3
  nosql/redis/__results_redis__march5 nosql/redis/__results_redis__march6 nosql/redis/__results_redis__.old
  nosql/redis/__results_redis__.tar.gz nosql/redis/results nosql/redis/results-stats
  nosql/redis/redis-polygon.good.march6 nosql/redis/redis-polygon.old nosql/redis/redis-polygon/old-builds
  sql/sqlite/results.good.6march sql/sqlite/results.old sql/sqlite/results.old1 sql/sqlite/tsan-logs.stale-2026-03-17
  sql/sqlite/vtune_results sql/sqlite/build/old-builds
  sql/mysql/benchmysql/results_16march sql/mysql/benchmysql/_old sql/mysql/benchmysql/_old_12march
  sql/mysql/partial-mysql-tsan-st sql/mysql/failed-mysql-tsan-ea
  sql/mysql/mysql-orig sql/mysql/mysql-tsan sql/mysql/mysql-tsan-dom sql/mysql/mysql-tsan-dom-ea-lo-st
  sql/mysql/mysql-tsan-dompeeling sql/mysql/mysql-tsan-dompeeling-ea-lo-st-swmr sql/mysql/mysql-tsan-dompeeling-ea-lo-st-swmr-stmt
  sql/mysql/mysql-tsan-ea sql/mysql/mysql-tsan-lo sql/mysql/mysql-tsan-sound sql/mysql/mysql-tsan-st sql/mysql/mysql-tsan-stmt sql/mysql/mysql-tsan-swmr
  projects/ffmpeg/results_ffmpeg_bak projects/ffmpeg/old projects/ffmpeg/old_5march projects/ffmpeg/ffmpeg-trace.log
  chromium/llvm-project
)
mkdir -p "$DEST"; MD=$DEST/ARCHIVE.md
[ -f "$MD" ] || printf "# Archive of stale tsan-experiments material — %s\n\nSource root: %s. Each entry: original path, size, tarball, sha256, file count.\n\n| path | size | tarball | sha256 | files |\n|---|---|---|---|---|\n" "$(date -Iseconds)" "$REPO" > "$MD"
echo "df before: $(df -h / | tail -1)"
for p in "${ARCHIVE_PATHS[@]}" projects/ffmpeg/results_threads-*; do
  [ -e "$p" ] || { echo "skip (absent): $p"; continue; }
  name=$(echo "$p" | tr '/' '__'); tb="$DEST/$name.tar.zst"; size=$(du -sh "$p" | cut -f1)
  nfiles=$(find "$p" | wc -l)
  echo "[$(date +%T)] archiving $p ($size, $nfiles entries) -> $tb"
  [ -n "$DRY" ] && continue
  tar -I 'zstd -T8 -3' -cf "$tb" "$p"
  ntar=$(tar -I zstd -tf "$tb" | wc -l)
  [ "$ntar" -ge "$nfiles" ] || { echo "ERROR: $tb lists $ntar entries, expected >= $nfiles"; exit 1; }
  sha=$(sha256sum "$tb" | cut -c1-16)
  printf "| %s | %s | %s | %s | %s |\n" "$p" "$size" "$(basename "$tb")" "$sha" "$nfiles" >> "$MD"
  rm -rf "$p"
done
# spot check: extract one tarball's listing head
first=$(ls "$DEST"/*.tar.zst | head -1); echo "spot check $first: $(tar -I zstd -tf "$first" | head -3 | tr '\n' ' ')"
[ -n "$DRY" ] || rm -rf /extra/alexey/tsan-experiments/eviction-traces
echo "df after: $(df -h / | tail -1)"; echo "CLEANUP DONE"
