#!/bin/bash
# move_out.sh <cfg> — relocate out/chrome-<cfg> from the SSD scratch to /extra/alexey/chromium/out and repoint the symlink.
set -euo pipefail; CFG=${1:?}; SRC=${SRC_DIR:-/extra/alexey/chromium/chromium/src}; DST=/extra/alexey/chromium/out
out="$SRC/out/chrome-$CFG"; [ -L "$out" ] || { echo "$out is not a symlink"; exit 1; }
tgt=$(readlink -f "$out"); mkdir -p "$DST"; rm -rf "$DST/chrome-$CFG"; mv "$tgt" "$DST/chrome-$CFG"; ln -sfn "$DST/chrome-$CFG" "$out"; echo "moved to $DST/chrome-$CFG"
