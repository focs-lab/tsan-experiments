#!/bin/bash
# stageB_accept_hash2.sh <hash2> — acceptance builds of the second stage-b copy (parser join-sharing + Chromium
# pointee views + shape 22), in the announced gap after tsan-dev's freeze: every Stage B configuration of the five
# applications, MySQL alone under the exclusive machine lock (build.sh does that), then the static-count diff
# against d3bf9f8c39fe — expected: identical except shape 22's few sites. Builds only; no measurement.
set -uo pipefail; cd "$(dirname "$0")"; source ./lib.sh; source ./configs.sh
H2=${1:?hash2}; OUT="$P5_DIR/results/stageB-$H2"; mkdir -p "$OUT/build"
p5_compiler_root "$H2" > /dev/null || exit 1
p5_log "acceptance builds on $H2 (stage-b2)"
for app in memcached redis sqlite ffmpeg; do P5_OUT="$OUT" ./build.sh "$app" "$H2" "$(p5_configs_for "$app" "$P5_ALL")" > "$OUT/build/build-$app.log" 2>&1 & done; wait
P5_OUT="$OUT" ./build.sh mysql "$H2" "$(p5_configs_for mysql "$P5_ALL")" > "$OUT/build/build-mysql.log" 2>&1
for app in memcached redis sqlite ffmpeg mysql; do echo "$app: $(grep -c '\] built ' "$OUT/build/build-$app.log") built, $(grep -c 'FAILED' "$OUT/build/build-$app.log") failed"; done
python3 static_diff.py results/stageB-d3bf9f8c39fe "$OUT" > "$OUT/static-diff-vs-d3bf9f8c39fe.md"; grep -vE "\| \+0 \||\| - \|" "$OUT/static-diff-vs-d3bf9f8c39fe.md"
grep -E "built mysql tsan-sound" "$OUT/build/build-mysql.log" | cut -c22-100
echo "ACCEPTANCE-$H2 DONE $(date -Iseconds)" >> "$OUT/build/builds.log"
