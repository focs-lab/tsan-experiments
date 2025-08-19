#!/bin/bash
set -e

BASE_DIR="$(pwd)/out"
TARGET="chrome"

for dir in "$BASE_DIR"/*/; do
    name=$(basename "$dir")
    echo "=== Compiling in $name ==="
    echo autoninja -C "$dir" "$TARGET"
    autoninja -C "$dir" "$TARGET"
done